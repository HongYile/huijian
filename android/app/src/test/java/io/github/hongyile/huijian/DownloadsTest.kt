package io.github.hongyile.huijian

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.util.concurrent.atomic.AtomicInteger

/** 附件下载：同一附件只下一份（SingleFlight），临时文件改名失败时的兜底（Api.commit） */
class DownloadsTest {
    private fun flight() = SingleFlight<String, Unit>(CoroutineScope(SupervisorJob() + Dispatchers.Default))

    @Test fun sameKeySharesOneRun() = runBlocking {
        val f = flight()
        val runs = AtomicInteger()
        val gate = CompletableDeferred<Unit>()
        val a = f.start("att1") { runs.incrementAndGet(); gate.await() }
        val b = f.start("att1") { runs.incrementAndGet(); gate.await() }
        assertSame(a, b)
        assertTrue(f.isRunning("att1"))
        gate.complete(Unit)
        a.await(); b.await()
        assertEquals(1, runs.get())
    }

    @Test fun finishedKeyCanRunAgainAndKeysAreIndependent() = runBlocking {
        val f = flight()
        val runs = AtomicInteger()
        f.start("x") { runs.incrementAndGet() }.await()
        val again = f.start("x") { runs.incrementAndGet() }
        again.await()
        assertEquals(2, runs.get())
        assertFalse(f.isRunning("x"))

        val gate = CompletableDeferred<Unit>()
        val p = f.start("p") { gate.await() }
        val q = f.start("q") { }
        assertNotSame(p, q)
        q.await()                       // 不同附件互不等待
        gate.complete(Unit); p.await()
    }

    @Test fun failureReachesEveryWaiter() = runBlocking {
        val f = flight()
        val gate = CompletableDeferred<Unit>()
        val a = f.start("bad") { gate.await(); throw IOException("附件校验失败") }
        val b = f.start("bad") { }
        gate.complete(Unit)
        for (d in listOf(a, b)) {
            try { d.await(); fail("应当失败") } catch (e: IOException) { assertEquals("附件校验失败", e.message) }
        }
        // 失败后可以重试
        f.start("bad") { }.await()
    }

    private fun dir(): File = Files.createTempDirectory("hy-att").toFile().apply { deleteOnExit() }

    @Test fun commitRenamesTempFile() {
        val d = dir()
        val tmp = File.createTempFile("att", ".part", d).apply { writeText("hello") }
        val dest = File(d, "a.txt")
        Api.commit(tmp, dest, Api.sha256(tmp))
        assertEquals("hello", dest.readText())
        assertFalse(tmp.exists())
    }

    @Test fun commitAcceptsDestWrittenByAnotherDownload() {
        val d = dir()
        val dest = File(d, "a.txt").apply { writeText("hello") }
        val want = Api.sha256(dest)
        val gone = File(d, "gone.part")                 // 改名失败（临时文件已不在）
        Api.commit(gone, dest, want)                     // 目标已存在且校验通过：算成功
        Api.commit(gone, dest, "")                       // 没有校验值时，目标存在即可
        assertEquals("hello", dest.readText())
    }

    @Test fun commitFailsWhenDestMissingOrWrong() {
        val d = dir()
        val gone = File(d, "gone.part")
        try { Api.commit(gone, File(d, "none.txt"), ""); fail() } catch (_: IOException) {}
        val dest = File(d, "a.txt").apply { writeText("other") }
        try { Api.commit(gone, dest, "00".repeat(32)); fail() } catch (_: IOException) {}
    }

    @Test fun uniqueTempNames() {
        val d = dir()
        val a = File.createTempFile("att", ".part", d)
        val b = File.createTempFile("att", ".part", d)
        assertNotSame(a.name, b.name)
        assertFalse(a.name == b.name)
    }
}
