import Foundation
import CommonCrypto
import CryptoKit

/// NetEase Cloud Music request encryption (weapi / eapi).
///
/// weapi: two rounds of AES-128-CBC over the JSON payload — first with a preset
/// key, then with a client-chosen secret key. The secret key is normally
/// RSA-encrypted per request; since the key is chosen by us, we ship a fixed
/// key with its RSA ciphertext precomputed, avoiding a BigInt implementation.
///
/// eapi: AES-128-ECB over "url + payload + md5 digest" with a fixed key, hex output.
enum NeteaseCrypto {
    private static let weapiPresetKey = "0CoJUm6Qyw8W8jud"
    private static let weapiIV = "0102030405060708"
    // DO NOT CHANGE LENGTH OR KEY WITHOUT RECOMPUTING encSecKey: this key
    // must stay exactly 16 bytes for AES-128, and weapiEncSecKey below is
    // the raw-RSA encryption (reverse the key, pow with exponent 65537 and
    // the NetEase modulus) of this exact key.
    private static let weapiSecretKey = "Kite200901272026"
    private static let weapiEncSecKey =
        "5fea198f30ecdd9e142c8c8a8cd4363b9e5fc21a56145b1514ec03df16af22fb" +
        "951f691d65d225c9ea6502fd8c0352956aa9d99bda184424096c74991448b981" +
        "0ced9d16a27d9f14fb799a3c03326dad50ad7f6644beb932e23dcfb16ceb5821" +
        "05487a24ab4869336d090685cd27660e208bbeb31a197a37561f40e7adc332ca"
    private static let eapiKey = "e82ckenh8dichen8"

    /// Encrypts a JSON payload for a `/weapi/...` endpoint.
    /// Returns the form body fields.
    static func weapi(payload: Data) -> [String: String] {
        let first = aes128(payload, key: weapiPresetKey, cbcIV: weapiIV).base64EncodedData()
        let second = aes128(first, key: weapiSecretKey, cbcIV: weapiIV).base64EncodedString()
        return ["params": second, "encSecKey": weapiEncSecKey]
    }

    /// Encrypts a JSON payload for an `/eapi/...` endpoint.
    /// - Parameter apiPath: the internal API path, e.g. "/api/song/enhance/player/url/v1"
    static func eapi(apiPath: String, payload: Data) -> [String: String] {
        let text = String(decoding: payload, as: UTF8.self)
        let message = "nobody\(apiPath)use\(text)md5forencrypt"
        let digest = Insecure.MD5.hash(data: Data(message.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let data = "\(apiPath)-36cd479b6b5-\(text)-36cd479b6b5-\(digest)"
        let encrypted = aes128(Data(data.utf8), key: eapiKey, cbcIV: nil)
        return ["params": encrypted.map { String(format: "%02X", $0) }.joined()]
    }

    /// AES-128 encryption with PKCS7 padding. CBC when `cbcIV` is given, ECB otherwise.
    private static func aes128(_ data: Data, key: String, cbcIV: String?) -> Data {
        let keyData = Data(key.utf8)
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var written = 0
        let options: CCOptions = cbcIV == nil
            ? CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode)
            : CCOptions(kCCOptionPKCS7Padding)
        let ivData = cbcIV.map { Data($0.utf8) }

        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { dataPtr in
                keyData.withUnsafeBytes { keyPtr in
                    if let ivData {
                        return ivData.withUnsafeBytes { ivPtr in
                            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                                    options, keyPtr.baseAddress, keyData.count, ivPtr.baseAddress,
                                    dataPtr.baseAddress, data.count,
                                    outPtr.baseAddress, outPtr.count, &written)
                        }
                    } else {
                        return CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                                       options, keyPtr.baseAddress, keyData.count, nil,
                                       dataPtr.baseAddress, data.count,
                                       outPtr.baseAddress, outPtr.count, &written)
                    }
                }
            }
        }
        precondition(status == kCCSuccess, "AES encryption failed: \(status)")
        return out.prefix(written)
    }
}
