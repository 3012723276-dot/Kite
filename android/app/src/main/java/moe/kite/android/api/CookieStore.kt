package moe.kite.android.api

import android.content.Context
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl

/**
 * 登录 Cookie 持久化：把网易云返回的 MUSIC_U 等 Cookie 存到
 * SharedPreferences，重启 App 后不用重登。
 * 安卓适配：不用 iOS 的 Keychain / HTTPCookieStorage，
 * 用 Android 自己的 SharedPreferences + OkHttp CookieJar。
 */
class PersistentCookieJar(context: Context) : CookieJar {
    private val prefs = context.getSharedPreferences("kite_cookies", Context.MODE_PRIVATE)
    private val memory = mutableMapOf<String, MutableList<Cookie>>()

    init {
        // 恢复上次保存的 Cookie（按 host 分组，简单序列化）
        prefs.all.forEach { (host, value) ->
            val raw = value as? String ?: return@forEach
            val cookies = raw.split(";").mapNotNull { part ->
                val kv = part.split("=", limit = 2)
                if (kv.size != 2) null else Cookie.Builder()
                    .domain(host)
                    .name(kv[0].trim())
                    .value(kv[1].trim())
                    .path("/")
                    .build()
            }
            if (cookies.isNotEmpty()) memory[host] = cookies.toMutableList()
        }
    }

    override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
        val host = url.host
        val list = memory.getOrPut(host) { mutableListOf() }
        cookies.forEach { newCookie ->
            list.removeAll { it.name == newCookie.name }
            list.add(newCookie)
        }
        val serialized = list.joinToString(";") { "${it.name}=${it.value}" }
        prefs.edit().putString(host, serialized).apply()
    }

    override fun loadForRequest(url: HttpUrl): List<Cookie> {
        // OkHttp 的 Cookie 没有 hasExpired，只有 expiresAt 时间戳，
        // 过期判断要自己用当前时间比，这就是 #5 编译失败的原因之一。
        val now = System.currentTimeMillis()
        return memory[url.host]?.filter { it.expiresAt >= now } ?: emptyList()
    }

    fun clear() {
        memory.clear()
        prefs.edit().clear().apply()
    }
}
