package moe.kite.android.api

import java.math.BigInteger
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec
import android.util.Base64

/**
 * 网易云 weapi 加密，与 iOS 版 NeteaseCrypto.swift 同一算法。
 *
 * 流程（iOS 版已验证）：
 * 1. params 先用 preset key 做 AES-128-CBC 加密
 * 2. 再用随机 16 字节 key 做第二次 AES-128-CBC 加密，得到 params
 * 3. 随机 key 逆序后做无填充 raw RSA，指数 0x10001，模数见 RSA_MODULUS，
 *    结果格式化为 256 位十六进制，得到 encSecKey
 *
 * 注意：WEAPI_SECRET_KEY / WEAPI_ENC_SEC_KEY 的取值必须与 iOS 版
 * NeteaseCrypto.swift 里的 weapiSecretKey / weapiEncSecKey 保持一致，
 * 否则服务器 RSA 解出的密钥对不上，weapi 请求会失败。
 * 这里留空占位，填入前请先核对 iOS 源码，不要把密钥发到公开渠道。
 */
object NeteaseCrypto {
    const val PRESET_KEY = "0CoJUm6Qyw8W8jud"
    const val IV = "0102030405060708"
    const val EAPI_KEY = "e82ckenh8dichen8"

    // TODO: 从 iOS 版 NeteaseCrypto.swift 复制 weapiSecretKey（16 字节）
    const val WEAPI_SECRET_KEY = ""

    // TODO: 从 iOS 版 NeteaseCrypto.swift 复制 weapiEncSecKey（256 位十六进制）
    // 注意：换密钥必须同时重算 encSecKey，只改密钥不改 encSecKey 会调不通。
    const val WEAPI_ENC_SEC_KEY = ""

    const val RSA_MODULUS =
        "00e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e0312ecbda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b424d813cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a22b8e7"

    fun aes128Encrypt(text: String, key: String): String {
        val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")
        cipher.init(
            Cipher.ENCRYPT_MODE,
            SecretKeySpec(key.toByteArray(Charsets.UTF_8), "AES"),
            IvParameterSpec(IV.toByteArray(Charsets.UTF_8))
        )
        val encrypted = cipher.doFinal(text.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(encrypted, Base64.NO_WRAP)
    }

    fun randomSecretKey(): String {
        val chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        val random = SecureRandom()
        return (1..16).map { chars[random.nextInt(chars.length)] }.joinToString("")
    }

    /** 对密钥逆序字符串做 raw RSA，返回 256 位十六进制 encSecKey。 */
    fun rsaEncryptReversedKey(secretKey: String): String {
        val reversed = secretKey.reversed().toByteArray(Charsets.UTF_8)
        val message = BigInteger(1, reversed)
        val modulus = BigInteger(RSA_MODULUS, 16)
        val exponent = BigInteger("10001", 16)
        val encrypted = message.modPow(exponent, modulus)
        return encrypted.toString(16).padStart(256, '0')
    }

    /** weapi 双层加密：返回 (params, encSecKey)。 */
    fun weapiEncrypt(json: String): Pair<String, String> {
        val first = aes128Encrypt(json, PRESET_KEY)
        val secretKey = randomSecretKey()
        val params = aes128Encrypt(first, secretKey)
        val encSecKey = rsaEncryptReversedKey(secretKey)
        return params to encSecKey
    }
}
