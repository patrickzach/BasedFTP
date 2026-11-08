import Foundation
import CCurl
import Darwin

private final class FTPCurlContext {
    let control: OperationControl
    let file: FileHandle?
    let upload: Bool
    let offset: UInt64
    let size: UInt64
    let progress: (UInt64) -> Void
    var error: Error?
    var written: UInt64 = 0
    init(control: OperationControl, file: FileHandle?, upload: Bool, offset: UInt64, size: UInt64, progress: @escaping (UInt64) -> Void) {
        self.control = control; self.file = file; self.upload = upload; self.offset = offset; self.size = size; self.progress = progress
    }
}

private let ftpCurlWrite: curl_write_callback = { bytes, size, count, opaque in
    guard let opaque, let bytes, size == 0 || count <= Int.max / size else { return 0 }
    let context = Unmanaged<FTPCurlContext>.fromOpaque(opaque).takeUnretainedValue()
    do {
        try context.control.checkpoint()
        let length = size * count
        guard let file = context.file, UInt64(length) <= context.size - context.offset - context.written else {
            throw FTPError.message("The FTP source changed size during download. The staging file is retained.")
        }
        try file.write(contentsOf: Data(bytes: bytes, count: length)); context.written += UInt64(length)
        return length
    } catch { context.error = error; return 0 }
}
private let ftpCurlRead: curl_read_callback = { bytes, size, count, opaque in
    guard let opaque, let bytes, size == 0 || count <= Int.max / size else { return Int(CURL_READFUNC_ABORT) }
    let context = Unmanaged<FTPCurlContext>.fromOpaque(opaque).takeUnretainedValue()
    do {
        try context.control.checkpoint()
        guard let file = context.file else { return 0 }
        let data = try file.read(upToCount: min(size * count, 65536)) ?? Data()
        data.withUnsafeBytes { raw in if let source = raw.baseAddress { bytes.update(from: source.assumingMemoryBound(to: CChar.self), count: data.count) } }
        return data.count
    } catch { context.error = error; return Int(CURL_READFUNC_ABORT) }
}
private let ftpCurlSeek: curl_seek_callback = { opaque, offset, origin in
    guard let opaque else { return CURL_SEEKFUNC_FAIL }
    let context = Unmanaged<FTPCurlContext>.fromOpaque(opaque).takeUnretainedValue()
    do {
        try context.control.checkpoint()
        guard origin == SEEK_SET, offset >= 0, let file = context.file else { return CURL_SEEKFUNC_CANTSEEK }
        try file.seek(toOffset: UInt64(offset)); return CURL_SEEKFUNC_OK
    } catch { context.error = error; return CURL_SEEKFUNC_FAIL }
}
private let ftpCurlProgress: curl_xferinfo_callback = { opaque, _, received, _, sent in
    guard let opaque else { return 1 }
    let context = Unmanaged<FTPCurlContext>.fromOpaque(opaque).takeUnretainedValue()
    do {
        try context.control.checkpoint()
        let amount = UInt64(max(0, context.upload ? sent : received))
        context.progress(context.offset + min(amount, context.size - context.offset)); return 0
    } catch { context.error = error; return 1 }
}

/// Serial command requests reuse a control connection instead of reauthenticating per deletion.
final class FTPCurlConnection {
    fileprivate var handle: UnsafeMutableRawPointer?
    init() throws { handle = try FTPCurl.makeHandle() }
    func close() { if let handle { curl_easy_cleanup(handle); self.handle = nil } }
    deinit { close() }
}

/// Synchronous system-libcurl requests, confined to the caller's worker task.
/// Callbacks and their Swift context live only for the duration of easy_perform.
enum FTPCurl {
    private static let initialization = curl_global_init(Int(CURL_GLOBAL_DEFAULT))
    fileprivate static func makeHandle() throws -> UnsafeMutableRawPointer {
        guard initialization == CURLE_OK, let handle = curl_easy_init() else { throw FTPError.message("Could not initialize the system FTP transport.") }
        return handle
    }
    private static func check(_ result: CURLcode) throws {
        guard result == CURLE_OK else { throw FTPError.message("Could not configure the FTP transport (libcurl \(result.rawValue)).") }
    }
    static func perform(profile: ServerProfile, password: String, url: String, control: OperationControl,
                        file: FileHandle? = nil, upload: Bool = false, offset: UInt64 = 0, size: UInt64 = 0,
                        commands: [String] = [], connection: FTPCurlConnection? = nil, progress: (UInt64) -> Void = { _ in }) throws {
        try control.checkpoint(); try profile.validate()
        guard profile.transport != .sftp else { throw FTPError.message("The FTP transport cannot be used with an SSH profile.") }
        let handle: UnsafeMutableRawPointer
        if let connection {
            guard let live = connection.handle else { throw FTPError.message("The FTP command connection is closed.") }
            handle = live; curl_easy_reset(handle)
        } else { handle = try makeHandle() }
        func releaseRequest() {
            // reset clears Swift callback pointers but keeps reusable live connections.
            if connection != nil { curl_easy_reset(handle) } else { curl_easy_cleanup(handle) }
        }
        var needsCleanup = true
        defer { if needsCleanup { releaseRequest() } }
        guard size <= UInt64(Int64.max), offset <= size else { throw FTPError.message("Invalid FTP transfer size or resume offset.") }
        try check(bftp_string(handle, CURLOPT_URL, url))
        try check(bftp_string(handle, CURLOPT_USERNAME, profile.user))
        try check(bftp_string(handle, CURLOPT_PASSWORD, password))
        try check(bftp_string(handle, CURLOPT_PROTOCOLS_STR, profile.transport.urlScheme))
        if profile.transport.usesTLS {
            try check(bftp_long(handle, CURLOPT_USE_SSL, Int(CURLUSESSL_ALL.rawValue)))
            try check(bftp_long(handle, CURLOPT_SSL_VERIFYPEER, 1))
            try check(bftp_long(handle, CURLOPT_SSL_VERIFYHOST, 2))
            try check(bftp_long(handle, CURLOPT_SSLVERSION, Int(CURL_SSLVERSION_TLSv1_2)))
            try check(bftp_long(handle, CURLOPT_FTPSSLAUTH, Int(CURLFTPAUTH_TLS.rawValue)))
            if !profile.caCertificatePath.isEmpty { try check(bftp_string(handle, CURLOPT_CAINFO, profile.resolvedCAPath)) }
        }
        try check(bftp_string(handle, CURLOPT_PROXY, ""))
        try check(bftp_string(handle, CURLOPT_NOPROXY, "*"))
        try check(bftp_long(handle, CURLOPT_NETRC, Int(CURL_NETRC_IGNORED.rawValue)))
        try check(bftp_long(handle, CURLOPT_NOSIGNAL, 1))
        try check(bftp_long(handle, CURLOPT_FTP_SKIP_PASV_IP, 1))
        try check(bftp_long(handle, CURLOPT_FTP_USE_EPSV, 1))
        try check(bftp_long(handle, CURLOPT_FTP_FILEMETHOD, Int(CURLFTPMETHOD_SINGLECWD.rawValue)))
        try check(bftp_long(handle, CURLOPT_CONNECTTIMEOUT, 15))
        try check(bftp_long(handle, CURLOPT_SERVER_RESPONSE_TIMEOUT, 60))
        try check(bftp_long(handle, CURLOPT_LOW_SPEED_LIMIT, 1))
        try check(bftp_long(handle, CURLOPT_LOW_SPEED_TIME, 60))
        try check(bftp_long(handle, CURLOPT_NOPROGRESS, 0))
        try check(bftp_long(handle, CURLOPT_PATH_AS_IS, 1))
        var quotes: UnsafeMutablePointer<curl_slist>?
        defer { curl_slist_free_all(quotes) }
        for command in ["*OPTS UTF8 ON"] + commands {
            guard let next = curl_slist_append(quotes, command) else { throw FTPError.message("Could not allocate FTP command buffer.") }
            quotes = next
        }
        try check(bftp_quotes(handle, quotes))
        if file == nil { try check(bftp_long(handle, CURLOPT_NOBODY, 1)) }
        if upload {
            try check(bftp_long(handle, CURLOPT_UPLOAD, 1))
            try check(bftp_offset(handle, CURLOPT_INFILESIZE_LARGE, Int(size)))
        }
        if offset > 0 { try check(bftp_offset(handle, CURLOPT_RESUME_FROM_LARGE, Int(offset))) }
        try withoutActuallyEscaping(progress) { callback in
            let context = FTPCurlContext(control: control, file: file, upload: upload, offset: offset, size: size, progress: callback)
            // libcurl may invoke callbacks while closing an FTP connection. Keep
            // their Swift context and nonescaping progress closure alive through cleanup.
            defer {
                withExtendedLifetime(context) { releaseRequest() }
                needsCleanup = false
            }
            let pointer = Unmanaged.passUnretained(context).toOpaque()
            for option in [CURLOPT_WRITEDATA, CURLOPT_READDATA, CURLOPT_SEEKDATA, CURLOPT_XFERINFODATA] { try check(bftp_pointer(handle, option, pointer)) }
            try check(bftp_write(handle, ftpCurlWrite)); try check(bftp_read(handle, ftpCurlRead))
            try check(bftp_seek(handle, ftpCurlSeek)); try check(bftp_progress(handle, ftpCurlProgress))
            let result = curl_easy_perform(handle)
            if let error = context.error { throw error }
            try control.checkpoint()
            if profile.transport.usesTLS {
                var verification: Int = 0
                try check(bftp_verify_result(handle, &verification))
                // A failed data-channel handshake may be surfaced as a generic FTP
                // response error; preserve the actual TLS verification diagnosis.
                if verification != 0 { throw FTPTLSError.certificate }
            }
            guard result == CURLE_OK else {
                if profile.transport.usesTLS, let error = FTPTLS.failure(code: Int(result.rawValue)) { throw error }
                // Server replies and error buffers may echo credentials; display only our own diagnostics.
                let message: String
                switch result {
                case CURLE_LOGIN_DENIED: message = "FTP login failed. Check the username and password."
                case CURLE_COULDNT_RESOLVE_HOST: message = "Could not resolve the FTP hostname."
                case CURLE_COULDNT_CONNECT: message = "Could not connect to the FTP server or passive data port."
                case CURLE_OPERATION_TIMEDOUT: message = "The FTP connection timed out. Retry or resume the transfer."
                case CURLE_REMOTE_ACCESS_DENIED, CURLE_QUOTE_ERROR, CURLE_UPLOAD_FAILED: message = "The FTP server rejected the operation. Check permissions and rename/overwrite support. Existing destinations are never deleted as a fallback."
                case CURLE_BAD_DOWNLOAD_RESUME, CURLE_RANGE_ERROR, CURLE_FTP_COULDNT_USE_REST: message = "The FTP server could not resume this transfer. Retry without Resume."
                default: message = "FTP transfer failed (libcurl \(result.rawValue)). The staging file is retained if one was created."
                }
                throw FTPError.message(message)
            }
            if file != nil && !upload && context.written != size - offset { throw FTPError.message("The FTP download ended before the expected size. The staging file is retained.") }
            progress(size)
        }
    }
}
