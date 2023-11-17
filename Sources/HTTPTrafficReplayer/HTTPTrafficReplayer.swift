// HTTPTrafficReplayer
//
// Copyright (c) 2023 carlbrown
//
// Orginal Copyright (c) 2015 muukii (for HTTPLogger)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import Foundation

@available(macOS 10.15, *)
public protocol HTTPTrafficReplayerConfigurationType {
    var behavior: HTTPTrafficReplayer.Behavior { get }
    var recordingDirectory: URL? { get }
    var filePrefix: String { get }
    var bodyTrimLength: Int { get }
    func printLog(_ string: String)
    func enableCapture(_ request: URLRequest) -> Bool
    func incrementSequence(_ request: URLRequest) -> Int?
    func fileNameWithoutExtension(_ request: URLRequest) -> String?
}

@available(macOS 10.15, *)
extension HTTPTrafficReplayerConfigurationType {
    
    public var behavior: HTTPTrafficReplayer.Behavior {
        return .logOnly
    }
    
    public var recordingDirectory: URL? {
            return nil
    }
    
    public var filePrefix: String {
            return "network-traffic"
    }
    
    public var bodyTrimLength: Int {
            return 1000
    }
        
    public func printLog(_ string: String) {
        print(string)
    }
    
    public func enableCapture(_ request: URLRequest) -> Bool {
        #if DEBUG
            return true
        #else
            return false
        #endif
    }
    
    public func incrementSequence(_ request: URLRequest) -> Int? {
        return nil
    }

    public func fileNameWithoutExtension(_ request: URLRequest) -> String? {
        return nil
    }
    
}

public enum HTTPTrafficReplayerError: Error {
    case unknownError
    case invalidConfigurationError
    case fileNotFoundError
}


@available(macOS 10.15, *)
public class HTTPTrafficReplayerDefaultConfiguration: HTTPTrafficReplayerConfigurationType {
    // just log by default
    public var behavior: HTTPTrafficReplayer.Behavior = .logOnly
    public var recordingDirectory: URL? = nil
    public var filePrefix: String = "network-traffic"
    public var bodyTrimLength: Int = 1000
    
    public var printLog: (_ string: String) -> Void = { string in
        print(string)
    }
    public var enableCapture: (_ request: URLRequest) -> Bool = { request in
        #if DEBUG
            return true
        #else
            return false
        #endif
    }
    
    // This has to be shaerd between different instances
    var sequenceCounter = [String: Int]()
    fileprivate var sequenceCounterConcurrencyLock = NSLock()
    
    public lazy var incrementSequence: (_ request: URLRequest) -> Int? = { [self] request in
        sequenceCounterConcurrencyLock.lock()
        defer { sequenceCounterConcurrencyLock.unlock() }
        guard let requestPrefix = fileNameWithoutExtension(request) else {
            return nil
        }
        
        if let currentValue = sequenceCounter[requestPrefix] {
            sequenceCounter[requestPrefix] = currentValue + 1
            return currentValue
        } else {
            sequenceCounter[requestPrefix] = 1
            return 0
        }
    }

    public lazy var fileNameWithoutExtension: (_ request: URLRequest) -> String? = { [self] request in
        guard let url=request.url, let method = request.httpMethod, let host = request.url?.host,
              let headers = request.allHTTPHeaderFields as? [String: AnyObject] else {
            return nil
        }
                
        let path = url.path.replacingOccurrences(of: "/", with: "%2F")
        var retVal = "\(self.filePrefix)+\(method)+\(host)+\(path)"
        return retVal
    }

}

@available(macOS 10.15, *)
public final class HTTPTrafficReplayer: URLProtocol, URLSessionDelegate {
    
    // MARK: - Public
    
    public enum Behavior {
        case logOnly
        case record
        case playback
    }

    public static var configuration: HTTPTrafficReplayerConfigurationType = HTTPTrafficReplayerDefaultConfiguration()
    
    public class func register() {
        URLProtocol.registerClass(self)
    }
    
    public class func unregister() {
        URLProtocol.unregisterClass(self)
    }
    
    public class func defaultSessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.protocolClasses?.insert(HTTPTrafficReplayer.self, at: 0)
        return config
    }
    
    //MARK: - NSURLProtocol
    
    public override class func canInit(with request: URLRequest) -> Bool {
        
        guard HTTPTrafficReplayer.configuration.enableCapture(request) == true else {
            return false
        }
        
        guard self.property(forKey: requestHandledKey, in: request) == nil else {
            return false
        }
        
        return true
    }
    
    public override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }
    
    public override class func requestIsCacheEquivalent(_ a: URLRequest, to b: URLRequest) -> Bool {
        return super.requestIsCacheEquivalent(a, to: b)
    }
    
    public override func startLoading() {
        guard let req = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest, newRequest == nil else {
            self.client?.urlProtocol(self, didFailWithError: HTTPTrafficReplayerError.unknownError)
            return
        }
        
        self.newRequest = req
        
        HTTPTrafficReplayer.setProperty(true, forKey: HTTPTrafficReplayer.requestHandledKey, in: newRequest!)
        HTTPTrafficReplayer.setProperty(Date(), forKey: HTTPTrafficReplayer.requestTimeKey, in: newRequest!)
        
        let session = Foundation.URLSession(configuration: URLSessionConfiguration.default, delegate: self, delegateQueue: nil)
        
        var fileNamePrefix: String?
        var sequenceNumber: Int?
        if !loggingOnly {
            do {
                fileNamePrefix = HTTPTrafficReplayer.configuration.fileNameWithoutExtension(request)
                sequenceNumber = HTTPTrafficReplayer.configuration.incrementSequence(request)
                try createStorageDirectoryIfNeeded()
            } catch {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
        }
        
        if self.playbackOnly, let fileNamePrefix, let sequenceNumber {
            do {
                if let (response, body, error) = try self.loadResponse(requestPrefix: fileNamePrefix, sequence: sequenceNumber, req: self.request) {
                    if let error {
                        self.client?.urlProtocol(self, didFailWithError: error)
                        return
                    }
                    
                    guard let body, let response else {
                        // If we didn't have an error, we should have had a reponse and a body, but we don't for some reason
                        self.client?.urlProtocol(self, didFailWithError: HTTPTrafficReplayerError.unknownError)
                        return
                    }
                    self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: URLCache.StoragePolicy.allowed)
                    self.client?.urlProtocol(self, didLoad: body)
                    self.client?.urlProtocolDidFinishLoading(self)
                    return
                } else {
                    self.client?.urlProtocol(self, didFailWithError: HTTPTrafficReplayerError.unknownError)
                    return
                }
            } catch {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
        }
        
        session.dataTask(with: request, completionHandler: { (data, response, error) -> Void in
            if self.recordingEnabled, let fileNamePrefix, let sequenceNumber {
                do {
                    try self.save(requestPrefix: fileNamePrefix, sequence: sequenceNumber, request: self.request, response: (response as? HTTPURLResponse))
                } catch {
                    self.client?.urlProtocol(self, didFailWithError: error)
                    return
                }
            }
            if let error = error {
                self.client?.urlProtocol(self, didFailWithError: error)
                if self.loggingOnly {
                    self.logError(error as NSError)
                }
                
                return
            }
            guard let response = response, let data = data else { return }
            

            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: URLCache.StoragePolicy.allowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
            if self.loggingOnly {
                self.logResponse(response, data: data)
            }
            }) .resume()
        
        if self.loggingOnly {
            logRequest(newRequest as? URLRequest)
        }
    }
    
    public override func stopLoading() {}
    
    func URLSession(
        _ session: Foundation.URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
                                   newRequest request: URLRequest,
                                              completionHandler: (URLRequest?) -> Void) {
        
        self.client?.urlProtocol(self, wasRedirectedTo: request, redirectResponse: response)
        
    }
    
    
    //MARK: - Logging
    
    public func logError(_ error: NSError) {
        
        var logString = "⚠️\n"
        logString += "Error: \n\(error.localizedDescription)\n"
        
        if let reason = error.localizedFailureReason {
            logString += "Reason: \(reason)\n"
        }
        
        if let suggestion = error.localizedRecoverySuggestion {
            logString += "Suggestion: \(suggestion)\n"
        }
        logString += "\n\n*************************\n\n"
        HTTPTrafficReplayer.configuration.printLog(logString)
    }
    
    public func logRequest(_ request: URLRequest?) {
        guard let request else {
            HTTPTrafficReplayer.configuration.printLog("\n📤\nERROR: Invalid Request!!\n\n*************************\n\n")
            return
        }
        var logString = "\n📤"
        if let url = request.url?.absoluteString {
            logString += "Request: \n  \(request.httpMethod!) \(url)\n"
        }
        
        if let headers = request.allHTTPHeaderFields {
            logString += "Header:\n"
            logString += logHeaders(headers as [String : AnyObject]) + "\n"
        }
        
        if let data = request.httpBody,
            let bodyString = NSString(data: data, encoding: String.Encoding.utf8.rawValue) {
            
            logString += "Body:\n"
            logString += trimTextOverflow(bodyString as String, length: HTTPTrafficReplayer.configuration.bodyTrimLength)
        }
        
        if let dataStream = request.httpBodyStream {
            
            let bufferSize = 1024
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            
            let data = NSMutableData()
            dataStream.open()
            while dataStream.hasBytesAvailable {
                let bytesRead = dataStream.read(&buffer, maxLength: bufferSize)
                data.append(buffer, length: bytesRead)
            }
            
            if let bodyString = NSString(data: data as Data, encoding: String.Encoding.utf8.rawValue) {
                logString += "Body:\n"
                logString += trimTextOverflow(bodyString as String, length: HTTPTrafficReplayer.configuration.bodyTrimLength)
            }
        }
        
        logString += "\n\n*************************\n\n"
        HTTPTrafficReplayer.configuration.printLog(logString)
    }
    
    public func logResponse(_ response: URLResponse, data: Data? = nil) {
        
        var logString = "\n📥"
        if let url = response.url?.absoluteString {
            logString += "Response: \n  \(url)\n"
        }
        
        if let httpResponse = response as? HTTPURLResponse {
            let localisedStatus = HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode).capitalized
            logString += "Status: \n  \(httpResponse.statusCode) - \(localisedStatus)\n"
        }
        
        if let headers = (response as? HTTPURLResponse)?.allHeaderFields as? [String: AnyObject] {
            logString += "Header: \n"
            logString += self.logHeaders(headers) + "\n"
        }
        
        if let startDate = HTTPTrafficReplayer.property(forKey: HTTPTrafficReplayer.requestTimeKey, in: newRequest! as URLRequest) as? Date {
            let difference = fabs(startDate.timeIntervalSinceNow)
            logString += "Duration: \n  \(difference)s\n"
        }
        
        guard let data = data else { return }
        
        if let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), contentType.contains("/gzip/") {
            
            do {
                let json = try JSONSerialization.jsonObject(with: data, options: .mutableContainers)
                let pretty = try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
                
                if let string = NSString(data: pretty, encoding: String.Encoding.utf8.rawValue) {
                    logString += "\nJSON: \n\(string)"
                }
            }
            catch {
                if let string = String(data: data, encoding: .utf8) {
                    logString += "\nData: \n\(string)"
                    HTTPTrafficReplayer.configuration.printLog(logString)
                }
            }
        } else {
            if let string = String(data: data, encoding: .utf8) {
                logString += "\nData: \n\(string)"
            }
        }
        
        logString += "\n\n*************************\n\n"
        HTTPTrafficReplayer.configuration.printLog(logString)
    }
    
    public func logHeaders(_ headers: [String: AnyObject]) -> String {
        
        let string = headers.reduce(String()) { str, header in
            let string = "  \(header.0) : \(header.1)"
            return str + "\n" + string
        }
        let logString = "[\(string)\n]"
        return logString
    }
    
    // MARK: - Private
    
    fileprivate static let requestHandledKey = "RequestHTTPTrafficReplayerHandledKey"
    fileprivate static let requestTimeKey = "RequestHTTPTrafficReplayerRequestTime"
    
    fileprivate var data: NSMutableData?
    fileprivate var response: URLResponse?
    fileprivate var newRequest: NSMutableURLRequest?
    
    fileprivate func trimTextOverflow(_ string: String, length: Int) -> String {
        
        guard string.lengthOfBytes(using: .utf8) > length else {
            return string
        }
        
        let index=string.index(string.startIndex, offsetBy: length)
        //return string.substring(to: string.characters.index(string.startIndex, offsetBy: length)) + "…"
        return string.prefix(upTo: index) + "…"
    }
    
    fileprivate var recordingEnabled: Bool {
        return HTTPTrafficReplayer.configuration.behavior == .record
    }
    
    fileprivate var playbackOnly: Bool {
        return HTTPTrafficReplayer.configuration.behavior == .playback
    }
    
    fileprivate var loggingOnly: Bool {
        return HTTPTrafficReplayer.configuration.behavior == .logOnly
    }

    fileprivate func createStorageDirectoryIfNeeded() throws {
        guard let recordingDirectory = HTTPTrafficReplayer.configuration.recordingDirectory else {
            throw HTTPTrafficReplayerError.fileNotFoundError
        }
        let fileManager = FileManager.default

        // Make sure the directory is valid
        if recordingEnabled {
            // does not throw if the directory already exists
            try fileManager.createDirectory(at: recordingDirectory, withIntermediateDirectories: true)
        } else {
            var isDir: ObjCBool = false
            let exists = fileManager.fileExists(atPath: recordingDirectory.standardizedFileURL.path, isDirectory: &isDir)
            if !exists || !isDir.boolValue {
                throw HTTPTrafficReplayerError.fileNotFoundError
            }
        }
    }
    
    fileprivate func save(requestPrefix: String, sequence: Int, request: URLRequest, response: HTTPURLResponse?, body: Data? = nil, error: Error? = nil) throws {
        guard let recordingDirectory = HTTPTrafficReplayer.configuration.recordingDirectory else {
            throw HTTPTrafficReplayerError.fileNotFoundError
        }

        let requestFileName = "\(requestPrefix)+request+\(String(format: "%02d", sequence)).plist"
            let responseFileName = "\(requestPrefix)+response+\(String(format: "%02d", sequence)).plist"
            let bodyFileName = "\(requestPrefix)+responseBody+\(String(format: "%02d", sequence)).plist"
            let errorFileName = "\(requestPrefix)+responseError+\(String(format: "%02d", sequence)).plist"
            do {
                let data = try NSKeyedArchiver.archivedData(
                    withRootObject: request,
                    requiringSecureCoding: false
                )
                
                try data.write(to: recordingDirectory.appendingPathComponent(requestFileName))

                if let response {
                    let data = try NSKeyedArchiver.archivedData(
                        withRootObject: response,
                        requiringSecureCoding: false
                    )
                    try data.write(to: recordingDirectory.appendingPathComponent(responseFileName))
                }
                
                if let data = body {
                    try data.write(to: recordingDirectory.appendingPathComponent(bodyFileName))
                }
                
                if let error {
                    let errorData = try NSKeyedArchiver.archivedData(
                        withRootObject: error,
                        requiringSecureCoding: false
                    )
                    try errorData.write(to: recordingDirectory.appendingPathComponent(errorFileName))
                }
            } catch {
                print("Test Network Recording error: \(error)")
            }
        }
        
    fileprivate func loadResponse(requestPrefix: String, sequence: Int, req: URLRequest) throws -> (response: HTTPURLResponse?, body: Data?, error: Error?)? {
            guard let recordingDirectory = HTTPTrafficReplayer.configuration.recordingDirectory else {
                throw HTTPTrafficReplayerError.fileNotFoundError
            }

            let responseFileName = "\(requestPrefix)+response+\(String(format: "%02d", sequence)).plist"
            let bodyFileName = "\(requestPrefix)+responseBody+\(String(format: "%02d", sequence)).plist"
            let errorFileName = "\(requestPrefix)+responseError+\(String(format: "%02d", sequence)).plist"
            do {
                let responseData = try Data(contentsOf: recordingDirectory.appendingPathComponent(responseFileName))
                let unarchiver = try NSKeyedUnarchiver(forReadingFrom: responseData)
                unarchiver.requiresSecureCoding = false
                let response = unarchiver.decodeObject(of: HTTPURLResponse.self, forKey: NSKeyedArchiveRootObjectKey)
                let bodyToReturn: Data? = try Data(contentsOf: recordingDirectory.appendingPathComponent(bodyFileName))

                var error: NSError?
                let fileManager = FileManager.default
                var isDir: ObjCBool = false
                let exists = fileManager.fileExists(atPath: recordingDirectory.appendingPathComponent(errorFileName).standardizedFileURL.path, isDirectory: &isDir)
                if exists && !isDir.boolValue {
                    let errorData = try Data(contentsOf: recordingDirectory.appendingPathComponent(errorFileName))
                    let unarchiver = try NSKeyedUnarchiver(forReadingFrom: errorData)
                    unarchiver.requiresSecureCoding = false
                    error = unarchiver.decodeObject(of: NSError.self, forKey: NSKeyedArchiveRootObjectKey)
                }

                return (response, bodyToReturn, error)
            } catch CocoaError.fileReadNoSuchFile {
                // no-op
            } catch CocoaError.fileNoSuchFile {
                // no-op
            } catch {
                print("Test Network Reading Back error: \(error)")
            }
            return nil
        }
        
        private func loadOriginalRequest(requestPrefix: String, recordingDirectory: URL, sequence: Int, req: URLRequest) throws -> NSURLRequest? {
            guard let recordingDirectory = HTTPTrafficReplayer.configuration.recordingDirectory else {
                throw HTTPTrafficReplayerError.fileNotFoundError
            }
            let requestFileName = "\(requestPrefix)+request+\(String(format: "%02d", sequence)).plist"
            do {
                let requestData = try Data(contentsOf: recordingDirectory.appendingPathComponent(requestFileName))
                let unarchiver = try NSKeyedUnarchiver(forReadingFrom: requestData)
                unarchiver.requiresSecureCoding = false
                let request = unarchiver.decodeObject(of: NSURLRequest.self, forKey: NSKeyedArchiveRootObjectKey)
                guard let request else {
                    return nil
                }
                return request
            } catch CocoaError.fileReadNoSuchFile {
                // no-op
            } catch CocoaError.fileNoSuchFile {
                // no-op
            } catch {
                print(error)
            }
            return nil
        }
}

