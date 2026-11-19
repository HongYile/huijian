package io.github.hongyile.huijian

/**
 * 带版本号的写盘：内存数据每改一次版本号加一，写盘时版本没超过上次写成的就跳过；写失败不记版本，下一次照样写。
 *
 * 同步服务每轮推进游标之前都无条件写一次：写盘失败后重试的那一轮，消息已经在内存里（合并时不算新消息），
 * 如果因为「没有新消息」就不写，游标却前进了，进程被杀后这批消息就丢了。版本号没变时直接返回，开销很小。
 */
class VersionedWriter {
    private var written = -1L

    /** valid 在锁内判断（例如登录会话没变），不成立就不写；返回是否真的写了 */
    @Synchronized
    fun write(version: Long, valid: () -> Boolean = { true }, sink: () -> Unit): Boolean {
        if (!valid() || version <= written) return false
        sink()
        written = version
        return true
    }

    /** 清空本地数据：等正在进行的写盘结束再执行 block，之后任何版本都会重新写 */
    @Synchronized
    fun clear(block: () -> Unit) {
        block()
        written = -1L
    }
}
