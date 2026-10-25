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
    // the NetEase modulus) of this exact key. The 0.1.1 restore used a
    // capital-K variant that would not match the server's decrypted key,
    // so this Kite key and its matching encSecKey replace it.
    private static let weapiSecretKey = "Kite2026abcDEF16"
    private static let weapiEncSecKey =
        "0be90bcb937777b506976d2f0c3740e31dd392ff43e52a409594e07b10588b92" +
        "c26ff4a429d4a1f782061afc42028f807e63396baf78735b443e5c5291f8e35e" +
        "ca26efb138072431ee4304c2c2a299891230e2ce39c346169a5ebf797f6b9d45" +
        "4b05abfd63b221236b43907458c0dcffb64faec1220e6ce2b8ab3361c4a4f055"
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
