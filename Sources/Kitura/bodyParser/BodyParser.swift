/**
 * Copyright IBM Corporation 2016
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 **/

import SwiftyJSON

import KituraSys
import KituraNet
import Socket
import LoggerAPI

import Foundation

// MARK: BodyParser


public class BodyParser: RouterMiddleware {

    ///
    /// Static buffer size (in bytes)
    ///
    private static let bufferSize = 2000


    ///
    /// BodyParser archiver
    ///
    private static let parserMap: [String: ((NSMutableData) -> ParsedBody?)] = ["application/json": BodyParser.parseJson,
                                                                                "application/x-www-form-urlencoded": BodyParser.parseURLencoded,
                                                                                "text": BodyParser.parseText]
    
    ///
    /// Initializes a BodyParser instance
    /// Needed since default initalizer is internal
    ///
    public init() {}

    ///
    /// Handle the request
    ///
    /// - Parameter request: the router request
    /// - Parameter response: the router response
    /// - Parameter next: the closure for the next execution block
    ///
    public func handle(request: RouterRequest, response: RouterResponse, next: () -> Void) throws {

        guard request.headers["Content-Length"] != nil, let contentType = request.headers["Content-Type"] else {
            return next()
        }

        request.body = BodyParser.parse(request, contentType: contentType)
        next()

    }

    ///
    /// Parse the incoming message
    ///
    /// - Parameter message: message coming from the socket
    /// - Parameter contentType: the contentType as a string
    ///
    public class func parse(_ message: SocketReader, contentType: String?) -> ParsedBody? {

        guard let contentType = contentType else {
            return nil
        }
        
        if let parser = getParsingFunction(contentType: contentType) {
            return parse(message, parser: parser)
        }
        
        return nil
    }
    
    private class func getParsingFunction(contentType: String) -> ((NSMutableData) -> ParsedBody?)? {
        // Handle Content-Type with parameters.  For example, treat:
        // "application/x-www-form-urlencoded; charset=UTF-8" as
        // "application/x-www-form-urlencoded"
        var contentTypeWithoutParameters = contentType
        if let parameterStart = contentTypeWithoutParameters.range(of: ";") {
            contentTypeWithoutParameters = contentType.substring(to: parameterStart.lowerBound)
        }
        if let parser = parserMap[contentTypeWithoutParameters] {
            return parser
        } else if let parser = parserMap["text"]
            where contentType.hasPrefix("text/") {
            return parser
        } else if contentType.hasPrefix("multipart/form-data") {
            guard let boundryIndex = contentType.range(of: "boundary=") else {
                return nil
            }
            let boundary = contentType.substring(from: boundryIndex.upperBound).replacingOccurrences(of: "\"", with: "")
            return  {(bodyData: NSMutableData) -> ParsedBody? in
                return parseMultipart(bodyData, boundary: boundary)
            }
        }
        return nil
    }

    ///
    /// Read incoming message for Parse
    ///
    /// - Parameter message: message coming from the socket
    /// - Parameter parser: ((NSMutableData) -> ParsedBody?) store at parserMap
    ///
    private class func parse(_ message: SocketReader, parser: ((NSMutableData) -> ParsedBody?)) -> ParsedBody? {
        do {
            let bodyData = try readBodyData(with: message)
            return parser(bodyData)
        } catch {
            Log.error("failed to read body data, error = \(error)")
        }
        return nil
    }

    ///
    /// Json parse Function
    ///
    /// - Parameter bodyData: read data
    ///
    private class func parseJson(_ bodyData: NSMutableData)-> ParsedBody? {
        let json = JSON(data: bodyData)
        if json != JSON.null {
            return .json(json)
        }
        return nil
    }

    ///
    /// Urlencoded parse Function
    ///
    /// - Parameter bodyData: read data
    ///
    private class func parseURLencoded(_ bodyData: NSMutableData)-> ParsedBody? {
        var parsedBody = [String:String]()
        var success = true
        if let bodyAsString: String = String(data: bodyData, encoding: NSUTF8StringEncoding) {

            let bodyAsArray = bodyAsString.components(separatedBy: "&")

            for element in bodyAsArray {

                let elementPair = element.components(separatedBy: "=")
                if elementPair.count == 2 {
                    parsedBody[elementPair[0]] = elementPair[1]
                } else {
                    success = false
                }
            }
            if success && parsedBody.count > 0 {
                return .urlEncoded(parsedBody)
            }
        }
        return nil
    }

    ///
    /// text parse Function
    ///
    /// - Parameter bodyData: read data
    ///
    private class func parseText(_ bodyData: NSMutableData)-> ParsedBody? {
        // There was no support for the application/json MIME type
        if let bodyAsString: String = String(data: bodyData, encoding: NSUTF8StringEncoding) {
            return .text(bodyAsString)
        }
        return nil
    }

    private enum ParseState {
        case preamble, body
    }

    ///
    /// Multipart form data parse function
    ///
    /// - Parameter bodyData: read data
    ///
    private class func parseMultipart(_ bodyData: NSMutableData, boundary: String) -> ParsedBody? {
        guard let boundaryData = String("--" + boundary).data(using: NSUTF8StringEncoding), let endBoundaryData = String("--" + boundary + "--").data(using: NSUTF8StringEncoding), let newLineData = "\r\n".data(using: NSUTF8StringEncoding) else {
            Log.error("Error converting strings to data for multipart parsing")
            return nil
        }

        var state = ParseState.preamble
        var parts: [Part] = []
        var currentPart = Part()
        var partData = NSMutableData()
        let bodyLines = divideDataByNewLines(data: bodyData, newLineData: newLineData)
        // main parse loop
        for bodyLine in bodyLines {
            switch(state) {
            case .preamble where bodyLine.hasPrefix(boundaryData), .body where bodyLine.hasPrefix(boundaryData):
                // boundary found
                state = handleBoundary(partData: &partData, currentPart: &currentPart, parts: &parts)

                if bodyLine.hasPrefix(endBoundaryData) {
                    // end boundary found, end of parsing
                    return .multipart(parts)
                }
            case .preamble:
                // discard preamble text
                break
            case .body:
                handleBodyLine(bodyLine, partData: &partData, currentPart: &currentPart)
            }
        }
        return nil
    }

    private class func handleBodyLine(_ bodyLine: NSData, partData: inout NSMutableData,
                                      currentPart: inout Part) {
        guard let newLineData = "\r\n".data(using: NSUTF8StringEncoding) else {
            Log.error("Error converting a string to newLineData for multipart parsing")
            return
        }

        // process bodyLine as String
        guard let line = String(data: bodyLine, encoding: NSUTF8StringEncoding) else {
            // is data, add to data object
            if partData.length > 0 {
                // data is multiline, add linebreaks back in
                partData.append(newLineData)
            }
            partData.append(bodyLine)
            return
        }

        let wasHeaderLine = handleHeaderLine(line, currentPart: &currentPart)

        if !wasHeaderLine && !line.isEmpty {
            // is data, add to data object
            if partData.length > 0 {
                // data is multiline, add linebreaks back in
                partData.append(newLineData)
            }
            partData.append(bodyLine)
        }
    }

    // returns true if it was header line
    private class func handleHeaderLine(_ line: String, currentPart: inout Part) -> Bool {
        if let labelRange = line.range(of: "content-type:", options: [.anchoredSearch, .caseInsensitiveSearch], range: line.startIndex..<line.endIndex) {
            currentPart.type = line.substring(from: line.index(after: labelRange.upperBound))
            currentPart.headers[.type] = line
            return true
        }

        if let labelRange = line.range(of: "content-disposition:", options: [.anchoredSearch, .caseInsensitiveSearch], range: line.startIndex..<line.endIndex) {
            if let nameRange = line.range(of: "name=", options: .caseInsensitiveSearch, range: labelRange.upperBound..<line.endIndex) {
                let valueStartIndex = line.index(after: nameRange.upperBound)
                let valueEndIndex = line.range(of: "\"", range: valueStartIndex..<line.endIndex)
                currentPart.name = line.substring(with: valueStartIndex..<(valueEndIndex?.lowerBound ?? line.endIndex))
            }
            currentPart.headers[.disposition] = line
            return true
        }

        if line.range(of: "content-transfer-encoding:", options: [.anchoredSearch, .caseInsensitiveSearch], range: line.startIndex..<line.endIndex) != nil {
            //TODO: Deal with this
            currentPart.headers[.transferEncoding] = line
            return true
        }

        return false
    }

    private class func handleBoundary(partData: inout NSMutableData,
                                      currentPart: inout Part, parts: inout [Part]) -> ParseState {
        if partData.length > 0 {
            if let parser = getParsingFunction(contentType: currentPart.type),
                let parsedBody = parser(partData) {
                currentPart.body = parsedBody
            } else {
                currentPart.body = .raw(partData)
            }
            parts.append(currentPart)
        }
        currentPart = Part()
        partData = NSMutableData()
        return .body
    }

    private class func divideDataByNewLines(data: NSData, newLineData: NSData) -> [NSData] {
        var dataLines = [NSData]()
        var lineStart = 0
        var currentPosition = 0
        while currentPosition < data.length - 1 {
            let newLineCanidate = data.subdata(with: NSRange(location: currentPosition, length: 2))
            if newLineCanidate.isEqual(to: newLineData) {
                dataLines.append(data.subdata(with: NSRange(location: lineStart, length: currentPosition - lineStart)))
                // skip new line characters
                currentPosition += 2
                lineStart = currentPosition
            } else {
                currentPosition += 1
            }
        }
        if lineStart != data.length {
            dataLines.append(data.subdata(with: NSRange(location: lineStart, length: data.length - lineStart)))
        }
        return dataLines
    }

    ///
    /// Read the Body data
    ///
    /// - Parameter reader: the socket reader
    ///
    /// - Throws: ???
    /// - Returns: data for the body
    ///
    public class func readBodyData(with reader: SocketReader) throws -> NSMutableData {

        let bodyData = NSMutableData()

        var length = try reader.read(into: bodyData)
        while length != 0 {
            length = try reader.read(into: bodyData)
        }
        return bodyData
    }

}

extension NSData {
    func hasPrefix(_ data: NSData) -> Bool {
        if data.length > self.length {
            return false
        }
        return self.subdata(with: NSRange(location: 0, length: data.length)).isEqual(to: data)
    }
}
