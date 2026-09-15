import Foundation

/// A self-signed test identity (CN=localhost, SAN=localhost/127.0.0.1) generated once with:
///
///     openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 36500 \
///         -nodes -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
///     openssl pkcs12 -export -out identity.p12 -inkey key.pem -in cert.pem -passout pass:testpass -legacy
///
/// Used to stand up a local, loopback-only TLS server in tests so certificate-expiry parsing can
/// be exercised deterministically instead of depending on a real external host.
enum CertificateFixtures {
    /// PKCS#12 bundle (certificate + private key), passphrase `p12Passphrase`. Valid for 100 years
    /// from generation (2026-09-15), so its expiry date is fixed and known ahead of time.
    static let p12Base64 = """
    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\
    VUEtFjsEEM8AMlwMb1vEsGgF8n7bZ4gCAggA
    """

    static let p12Passphrase = "testpass"

    /// The leaf certificate's DER encoding, extracted from the same PKCS#12 bundle above.
    static let leafCertificateDERBase64 = """
    MIIDJzCCAg+gAwIBAgIUON5g+svsMnUfu24FmuH66+mmQmAwDQYJKoZIhvcNAQELBQAwFDESMBAG\
    A1UEAwwJbG9jYWxob3N0MCAXDTI2MDkxNTExMzcwNloYDzIxMjYwODIyMTEzNzA2WjAUMRIwEAYD\
    VQQDDAlsb2NhbGhvc3QwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDT8xtoIKRENmsA\
    jy2tJkDRQbpH+rQ22Hjp8aNyiBOQrYdIJuRhPgn7DJV8WQbujvLSlA5ZIapZTecBTCDPhmu8hTEe\
    MRmq4Xo8aqmMRWe5bE2WhECMTR0fMLA7/GD1cqJwES2Ehg7O90c9rX1l1h7VfedYrsWMS9fUbUBu\
    HSLVubofJE8dlT/wtOl29lHAchREqr9CFbn9LYy8E7hBgrFBhiEYhoUa1awkyQwPaebYWmj0OFaE\
    eHCad5h1l3twY+7dPrj19QUh6bWdHpusXoO9faNU7HGtHT5IbOgV9njPlXiwUOPVupgdGqIycuU0\
    pnjOCwuphuYdDHB8MIiQnX8rAgMBAAGjbzBtMB0GA1UdDgQWBBQbLJiTmuDPJ5nG3p6W+KKw5PAH\
    wDAfBgNVHSMEGDAWgBQbLJiTmuDPJ5nG3p6W+KKw5PAHwDAPBgNVHRMBAf8EBTADAQH/MBoGA1Ud\
    EQQTMBGCCWxvY2FsaG9zdIcEfwAAATANBgkqhkiG9w0BAQsFAAOCAQEALUtcoY/d0TU3rmYkWkoM\
    djc2OpABCIuyX83xCyK+VuGHPOfkbqI5XKIanKV3VGpmLHdio3liIiiuoFgRGHTFR8dwSscR35Ok\
    DOr4fk+vu2gG99dMmRgoGQG/zO0cLfhUY2QJgtltRoFN+UpxjcOGgj7N0k7sbwCWW/D6cLAvkoFJ\
    d/w2wfR6x/EGW0n8iWZtCURFC2pcQ0Wo2t3QkICltoE5e37RBFbTfzm5W9bpvHbPCIxFJiscYewz\
    09lX1uCqG6rTJmUp9eJKvgwwAPB3DkLDDpdPQHE9AyI+uAqSsGAb1r2n+YMvE6NvyUrmnU5QWd1MF\
    uM7V8MupmTlsle77Q==
    """

    /// Fixed `NotAfter` (expiry) instant baked into the certificate above: 2126-08-22 11:37:06 UTC.
    static let leafCertificateExpiry: Date = {
        var components = DateComponents()
        components.year = 2126
        components.month = 8
        components.day = 22
        components.hour = 11
        components.minute = 37
        components.second = 6
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }()
}
