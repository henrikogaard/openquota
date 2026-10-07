import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    /// Per-request ceiling, seconds. Hard-bounded by the client.
    public var timeout: TimeInterval
    public var allowsRedirects: Bool

    public init(
        method: String = "GET",
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 15,
        allowsRedirects: Bool = true
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.allowsRedirects = allowsRedirects
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    public var retryAfter: TimeInterval? {
        guard let raw = headers.first(where: { $0.key.lowercased() == "retry-after" })?.value else { return nil }
        if let seconds = TimeInterval(raw), seconds.isFinite { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter.date(from: raw).map { max(0, $0.timeIntervalSinceNow) }
    }
}

public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// The app's single shared session. Hard timeouts everywhere — CodexBar #1005
/// showed a blocked network + URLSession defaults (7-day resource timeout)
/// hangs every provider fetch forever.
public final class URLSessionHTTPClient: HTTPClient, @unchecked Sendable {
    private let session: URLSession
    private let maxTimeout: TimeInterval
    private let maxResponseBytes = 2 * 1024 * 1024

    public init(maxTimeout: TimeInterval = 60) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        #if os(macOS)
        config.waitsForConnectivity = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        #endif
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
        self.maxTimeout = maxTimeout
    }

    deinit { session.invalidateAndCancel() }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = min(request.timeout, maxTimeout)
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response): (Data, URLResponse)
        let delegate = request.allowsRedirects ? nil : NoRedirectsDelegate()
        do {
            #if os(macOS)
            let (bytes, streamedResponse) = try await session.bytes(for: urlRequest, delegate: delegate)
            var buffer = Data()
            for try await byte in bytes {
                guard buffer.count < maxResponseBytes else {
                    throw ProviderError.badResponse("response exceeds 2 MB")
                }
                buffer.append(byte)
            }
            (data, response) = (buffer, streamedResponse)
            #else
            (data, response) = try await session.data(for: urlRequest, delegate: delegate)
            guard data.count <= maxResponseBytes else {
                throw ProviderError.badResponse("response exceeds 2 MB")
            }
            #endif
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as ProviderError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw ProviderError.timedOut
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.badResponse("non-HTTP response")
        }
        var headers: [String: String] = [:]
        for case let (key as String, value as String) in http.allHeaderFields {
            headers[key] = value
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: data)
    }
}

final class NoRedirectsDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Convenience: map a response's status to the standard error set, or return body.
public func requireOK(_ response: HTTPResponse) throws -> Data {
    switch response.status {
    case 200 ..< 300: return response.body
    case 401, 403: throw ProviderError.unauthorized
    case 429: throw ProviderError.rateLimited(retryAfter: response.retryAfter)
    default: throw ProviderError.serverError(response.status)
    }
}
