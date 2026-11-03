import Foundation
import Network
import SwiftpolisDomain

/// Builds sessions and requests carrying a Download's options.
struct RequestFactory: Sendable {
    let request: DownloadRequest
    let secrets: DownloadSecrets
    let settings: EngineSettings

    func makeSession(delegate: URLSessionDelegate, delegateQueue: OperationQueue?) -> URLSession {
        URLSession(configuration: makeConfiguration(), delegate: delegate, delegateQueue: delegateQueue)
    }

    func make(method: String, range: String? = nil) -> URLRequest {
        var urlRequest = URLRequest(url: URL(string: request.link) ?? URL(filePath: "/"))
        urlRequest.httpMethod = method
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.setValue(request.userAgent ?? settings.userAgent, forHTTPHeaderField: "User-Agent")
        // Compression would change the byte offsets that Parts depend on.
        urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let referer = request.referer {
            urlRequest.setValue(referer, forHTTPHeaderField: "Referer")
        }
        if let user = request.httpUser {
            urlRequest.setValue(
                Self.basicAuthorization(user: user, password: secrets.httpPassword ?? ""),
                forHTTPHeaderField: "Authorization"
            )
        }
        if let proxy = request.proxy, proxy.kind == .http, let user = proxy.user {
            urlRequest.setValue(
                Self.basicAuthorization(user: user, password: secrets.proxyPassword ?? ""),
                forHTTPHeaderField: "Proxy-Authorization"
            )
        }
        if let headers = request.headers {
            for (name, value) in RequestText.headers(from: headers) {
                urlRequest.setValue(value, forHTTPHeaderField: name)
            }
        }
        if let range {
            urlRequest.setValue(range, forHTTPHeaderField: "Range")
        }
        if let browserCookies = secrets.cookieHeader {
            // URLSession would replace this header with its own cookie store's, so the store's
            // cookies are added by hand instead.
            urlRequest.httpShouldHandleCookies = false
            let cookies = [browserCookies, fileCookieHeader(for: urlRequest.url)].compactMap { $0 }
            urlRequest.setValue(cookies.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        }
        return urlRequest
    }

    private func fileCookieHeader(for url: URL?) -> String? {
        guard let url else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        applyCookies(to: configuration)
        guard let cookies = configuration.httpCookieStorage?.cookies(for: url), !cookies.isEmpty else { return nil }
        return HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
    }

    /// The words Persepolis uses for a failed request, shown to the user.
    static func message(for error: Error) -> String {
        guard let error = error as? URLError else { return "Request error" }
        switch error.code {
        case .timedOut:
            return "Timeout error"
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet,
             .dnsLookupFailed, .secureConnectionFailed, .serverCertificateUntrusted:
            return "Connection error"
        default:
            return "Request error"
        }
    }

    private static func basicAuthorization(user: String, password: String) -> String {
        "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
    }

    private func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = settings.timeout
        configuration.timeoutIntervalForResource = 30 * 24 * 60 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        applyProxy(to: configuration)
        applyCookies(to: configuration)
        return configuration
    }

    private func applyProxy(to configuration: URLSessionConfiguration) {
        guard let proxy = request.proxy else { return }
        switch proxy.kind {
        case .http:
            // Unlike ProxyConfiguration, this sends plain HTTP as an ordinary proxied GET. Many
            // proxies refuse the CONNECT to port 80 that ProxyConfiguration would use.
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable: true,
                kCFNetworkProxiesHTTPProxy: proxy.host,
                kCFNetworkProxiesHTTPPort: proxy.port,
                kCFNetworkProxiesHTTPSEnable: true,
                kCFNetworkProxiesHTTPSProxy: proxy.host,
                kCFNetworkProxiesHTTPSPort: proxy.port,
            ] as [AnyHashable: Any]
        case .socks5:
            guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: proxy.port)) else { return }
            var configurationEntry = ProxyConfiguration(
                socksv5Proxy: .hostPort(host: NWEndpoint.Host(proxy.host), port: port)
            )
            if let user = proxy.user {
                configurationEntry.applyCredential(username: user, password: secrets.proxyPassword ?? "")
            }
            configuration.proxyConfigurations = [configurationEntry]
        }
    }

    private func applyCookies(to configuration: URLSessionConfiguration) {
        guard let path = request.cookieFilePath,
              let text = try? String(contentsOfFile: path, encoding: .utf8)
        else { return }
        for cookie in RequestText.cookies(from: text) {
            let properties: [HTTPCookiePropertyKey: Any] = [
                .domain: cookie.domain,
                .path: cookie.path,
                .name: cookie.name,
                .value: cookie.value,
            ]
            if let httpCookie = HTTPCookie(properties: properties) {
                configuration.httpCookieStorage?.setCookie(httpCookie)
            }
        }
    }
}

/// The rules that apply to every request: redirects and authentication challenges.
class RequestPolicyDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let requests: RequestFactory

    init(requests: RequestFactory) {
        self.requests = requests
    }

    /// Follows redirects, but doesn't hand a password or browser cookies to a different host.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var redirected = newRequest
        if newRequest.url?.host != task.originalRequest?.url?.host {
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
            redirected.setValue(nil, forHTTPHeaderField: "Cookie")
        }
        completionHandler(redirected)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        if space.isProxy(), challenge.previousFailureCount == 0, let user = requests.request.proxy?.user {
            let credential = URLCredential(
                user: user,
                password: requests.secrets.proxyPassword ?? "",
                persistence: .forSession
            )
            completionHandler(.useCredential, credential)
        } else if space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  !requests.settings.verifiesCertificates,
                  let trust = space.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
