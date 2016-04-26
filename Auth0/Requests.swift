// Requests.swift
//
// Copyright (c) 2016 Auth0 (http://auth0.com)
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
import Alamofire

public typealias DatabaseUser = (email: String, username: String?, verified: Bool)

public struct ConcatRequest<F, S>: Request {
    let first: AuthenticationRequest<F>
    let second: AuthenticationRequest<S>

    func start(callback: Result<S, Authentication.Error> -> ()) {
        let second = self.second
        first.start { result in
            switch result {
            case .Failure(let cause):
                callback(.Failure(error: cause))
            case .Success:
                second.start(callback)
            }
        }
    }
}

public struct AuthenticationRequest<T>: Request {
    public typealias AuthenticationCallback = Result<T, Authentication.Error> -> ()

    let manager: Alamofire.Manager
    let url: NSURL
    let method: Alamofire.Method
    let execute: (Alamofire.Request, AuthenticationCallback) -> ()
    var payload: [String: AnyObject] = [:]

    public func start(callback: AuthenticationCallback) {
        let request = manager.request(method, url, parameters: payload).validate()
        execute(request, callback)
    }

    public func concat<N>(request: AuthenticationRequest<N>) -> ConcatRequest<T, N> {
        return ConcatRequest(first: self, second: request)
    }
}

public struct FoundationRequest<T>: Request {
    public typealias AuthenticationCallback = Result<T, Authentication.Error> -> ()

    let session: NSURLSession
    let url: NSURL
    let method: String
    let execute: (Response, AuthenticationCallback) -> ()
    var payload: [String: AnyObject] = [:]

    public func start(callback: AuthenticationCallback) {
        let request = NSMutableURLRequest(URL: url)
        request.HTTPMethod = method
        request.HTTPBody = try! NSJSONSerialization.dataWithJSONObject(payload, options: [])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let handler = self.execute

        NSURLProtocol.setProperty(payload, forKey: "com.auth0.parameter", inRequest: request)

        session.dataTaskWithRequest(request) { data, response, error in
            handler(Response(data: data, response: response, error: error), callback)
        }.resume()
    }
}

struct Response {
    let data: NSData?
    let response: NSURLResponse?
    let error: NSError?

    var result: Result {
        guard error == nil else { return .Failure(error!) }
        guard let response = self.response as? NSHTTPURLResponse else { return .Failure(Error.Unknown.error) }
        guard (200...300).contains(response.statusCode) else { return .Failure(Error.RequestFailed.error) }
        guard let data = self.data else { return response.statusCode == 204 ? .Success(nil) : .Failure(Error.NoResponse.error) }
        do {
            let json = try NSJSONSerialization.JSONObjectWithData(data, options: [])
            return .Success(json)
        } catch {
            return .Failure(Error.InvalidJSON.error)
        }
    }

    enum Result {
        case Success(AnyObject?)
        case Failure(NSError)
    }

    enum Error: Int {
        case Unknown = 0
        case RequestFailed
        case NoResponse
        case InvalidJSON

        var error: NSError {
            let message: String
            switch self {
            case .Unknown:
                message = "Request failed with no apparent cause"
            case .RequestFailed:
                message = "HTTP status code was not successful"
            case .NoResponse:
                message = "Expected JSON response but got an empty one"
            case .InvalidJSON:
                message = "Malformed JSON in response body"
            }
            return NSError(domain: "com.auth0", code: self.rawValue, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}

func databaseUser(request: Alamofire.Request, callback: AuthenticationRequest<DatabaseUser>.AuthenticationCallback) {
    request.responseJSON { response in
        switch response.result {
        case .Success(let payload):
            if let dictionary = payload as? [String: String], let email: String = dictionary["email"] {
                let username = payload["username"] as? String
                let verified = payload["email_verified"] as? Bool ?? false
                callback(.Success(result: (email: email, username: username, verified: verified)))
            } else {
                callback(.Failure(error: .InvalidResponse(response: payload)))
            }
        case .Failure(let cause):
            callback(.Failure(error: authenticationError(response, cause: cause)))
        }
    }
}

func noBody(request: Alamofire.Request, callback: AuthenticationRequest<Void>.AuthenticationCallback) {
    request.responseData { response in
        switch response.result {
        case .Success:
            callback(.Success(result: ()))
        case .Failure(let cause):
            callback(.Failure(error: authenticationError(response.data, cause: cause)))
        }
    }
}

func credentials2(response: Response, callback: AuthenticationRequest<Credentials>.AuthenticationCallback) {
    switch response.result {
    case .Success(let payload):
        if let dictionary = payload as? [String: String], let credentials = Credentials(dictionary: dictionary) {
            callback(.Success(result: credentials))
        } else {
            callback(.Failure(error: .InvalidResponse(response: payload ?? [:])))
        }
    case .Failure(let cause):
        callback(.Failure(error: authenticationError(response.data, cause: cause)))
    }
}

func credentials(request: Alamofire.Request, callback: AuthenticationRequest<Credentials>.AuthenticationCallback) {
    request.responseJSON { response in
        switch response.result {
        case .Success(let payload):
            if let dictionary = payload as? [String: String], let credentials = Credentials(dictionary: dictionary) {
                callback(.Success(result: credentials))
            } else {
                callback(.Failure(error: .InvalidResponse(response: payload)))
            }
        case .Failure(let cause):
            callback(.Failure(error: authenticationError(response, cause: cause)))
        }
    }
}

private func authenticationError(response: Alamofire.Response<AnyObject, NSError>, cause: NSError) -> Authentication.Error {
    if let jsonData = response.data {
        return authenticationError(jsonData, cause: cause)
    } else {
        return .Unknown(cause: cause)
    }
}

private func authenticationError(data: NSData?, cause: NSError) -> Authentication.Error {
    if
        let data = data,
        let json = try? NSJSONSerialization.JSONObjectWithData(data, options: NSJSONReadingOptions()),
        let payload = json as? [String: AnyObject] {
        return payloadError(payload, cause: cause)
    } else {
        return .Unknown(cause: cause)
    }
}

private func payloadError(payload: [String: AnyObject], cause: ErrorType) -> Authentication.Error {
    if let code = payload["error"] as? String, let description = payload["error_description"] as? String {
        return .Response(code: code, description: description)
    }

    if let code = payload["code"] as? String, let description = payload["description"] as? String {
        return .Response(code: code, description: description)
    }

    return .Unknown(cause: cause)
}
