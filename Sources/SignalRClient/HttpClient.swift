// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - HttpRequest and HttpResponse

public enum HttpMethod: String, Sendable {
    case GET, PUT, PATCH, POST, DELETE
}

public struct HttpRequest: Sendable {
    var method: HttpMethod
    var url: String
    var content: StringOrData?
    var headers: [String: String]
    var timeout: TimeInterval
    var responseType: TransferFormat

    public init(
        method: HttpMethod, url: String, content: StringOrData? = nil,
        responseType: TransferFormat? = nil,
        headers: [String: String]? = nil, timeout: TimeInterval? = nil
    ) {
        self.method = method
        self.url = url
        self.content = content
        self.headers = headers ?? [:]
        self.timeout = timeout ?? 100
        if responseType != nil {
            self.responseType = responseType!
        } else {
            switch content {
            case .data(_):
                self.responseType = TransferFormat.binary
            default:
                self.responseType = TransferFormat.text
            }
        }
    }
}

public struct HttpResponse {
    public let statusCode: Int
}

// MARK: - HttpClient Protocol

public protocol HttpClient: Sendable {
    // Don't throw if the http call returns a status code out of [200, 299]
    func send(request: HttpRequest) async throws -> (StringOrData, HttpResponse)
}

actor DefaultHttpClient: HttpClient {
    private let logger: Logger
    private let session: URLSession

    init(logger: Logger) {
        self.logger = logger
        self.session = URLSession(configuration: URLSessionConfiguration.default)
    }

    public func send(request: HttpRequest) async throws -> (
        StringOrData, HttpResponse
    ) {
        do {
            let urlRequest = try request.buildURLRequest()
            let (data, response) = try await self.session.data(
                for: urlRequest)
            guard let httpURLResponse = response as? HTTPURLResponse else {
                throw SignalRError.invalidResponseType
            }
            let httpResponse = HttpResponse(
                statusCode: httpURLResponse.statusCode)
            let message = try data.convertToStringOrData(
                transferFormat: request.responseType)
            return (message, httpResponse)
        } catch {
            if let urlError = error as? URLError,
               urlError.code == URLError.timedOut {
                logger.log(
                    level: .warning, message: "Timeout from HTTP request."
                )
                throw SignalRError.httpTimeoutError
            }
            logger.log(
                level: .warning, message: "Error from HTTP request: \(error)"
            )
            throw error
        }
    }
}

typealias AccessTokenFactory = () async throws -> String?

actor AccessTokenHttpClient: HttpClient {
    var accessTokenFactory: AccessTokenFactory?
    var connectionATFactory: AccessTokenFactory?
    var accessToken: String?           // cached token for accessTokenFactory (negotiate + fallback)
    var connectionAccessToken: String? // cached token for connectionATFactory (non-negotiate)
    private let innerClient: HttpClient

    public init(
        innerClient: HttpClient,
        accessTokenFactory: AccessTokenFactory?
    ) {
        self.innerClient = innerClient
        self.accessTokenFactory = accessTokenFactory
        self.connectionATFactory = nil
    }

    public init(
        innerClient: HttpClient,
        accessTokenFactory: AccessTokenFactory?,
        connectionATFactory: AccessTokenFactory?
    ) {
        self.innerClient = innerClient
        self.accessTokenFactory = accessTokenFactory
        self.connectionATFactory = connectionATFactory
    }

    public func setAccessTokenFactory(accessTokenFactory: AccessTokenFactory?, connectionATFactory: AccessTokenFactory?) {
        self.accessTokenFactory = accessTokenFactory
        self.connectionATFactory = connectionATFactory
        self.accessToken = nil
        self.connectionAccessToken = nil
    }

    public func send(request: HttpRequest) async throws -> (
        StringOrData, HttpResponse
    ) {
        var mutableRequest = request
        let isNegotiateRequest = isNegotiateRequest(url: request.url)
        let allowRetry = !isNegotiateRequest

        if isNegotiateRequest {
            if let factory = connectionATFactory {
                // Redirect negotiate (e.g. Azure SignalR Service): the first negotiate
                // response returned a redirect URL + access token. The redirect target
                // only accepts that service-issued token, NOT the original MSAL token.
                connectionAccessToken = try await factory()
            } else if let factory = accessTokenFactory {
                // Initial negotiate: use the caller-supplied token (e.g. MSAL).
                accessToken = try await factory()
            }
        } else {
            // Non-negotiate uses connectionATFactory when set (token from negotiate response),
            // falling back to accessTokenFactory. Each factory has its own cache.
            if let factory = connectionATFactory {
                if connectionAccessToken == nil {
                    connectionAccessToken = try await factory()
                }
            } else if let factory = accessTokenFactory, accessToken == nil {
                accessToken = try await factory()
            }
        }

        setAuthorizationHeader(request: &mutableRequest)

        var (data, httpResponse) = try await innerClient.send(
            request: mutableRequest)

        if allowRetry && httpResponse.statusCode == 401,
           let factory = accessTokenFactory {
            accessToken = try await factory()
            setAuthorizationHeader(request: &mutableRequest)
            (data, httpResponse) = try await innerClient.send(
                request: mutableRequest)

            return (data, httpResponse)
        }

        return (data, httpResponse)
    }

    private func isNegotiateRequest(url: String) -> Bool {
        guard let urlComponents = URLComponents(string: url) else {
            return url.lowercased().contains("/negotiate")
        }

        let path = urlComponents.path.lowercased()
        return path.hasSuffix("/negotiate") || path.hasSuffix("/negotiate/")
    }

    private func setAuthorizationHeader(request: inout HttpRequest) {
        // connectionAccessToken takes precedence: it holds the service-issued token
        // (from a negotiate redirect response), which must be used for both the
        // redirect negotiate and all subsequent transport requests.
        let token = connectionAccessToken ?? accessToken
        if let token {
            request.headers["Authorization"] = "Bearer \(token)"
        } else if accessTokenFactory != nil || connectionATFactory != nil {
            request.headers.removeValue(forKey: "Authorization")
        }
    }
}

extension HttpRequest {
    fileprivate func buildURLRequest() throws -> URLRequest {
        guard let url = URL(string: self.url) else {
            throw SignalRError.invalidUrl(self.url)
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method.rawValue
        urlRequest.timeoutInterval = timeout
        for (key, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        switch content {
        case .data(let data):
            urlRequest.httpBody = data
            urlRequest.setValue(
                "application/octet-stream", forHTTPHeaderField: "Content-Type"
            )
        case .string(let strData):
            urlRequest.httpBody = strData.data(using: .utf8)
            urlRequest.setValue(
                "text/plain;charset=UTF-8", forHTTPHeaderField: "Content-Type"
            )
        case nil:
            break
        }
        return urlRequest
    }
}

extension HttpResponse {
    func ok() -> Bool {
        return statusCode >= 200 && statusCode < 300
    }
}
