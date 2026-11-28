package cn.iepose.lovespace.love_space

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AmapShadowEvalTest {
    @Test
    fun throttleAndCacheGate_followNativeCadence() {
        assertTrue(AmapShadowGate.shouldTriggerNewRequest(1_000L, 0L, inFlight = false))
        assertFalse(AmapShadowGate.shouldTriggerNewRequest(10_000L, 1_000L, inFlight = false))
        assertFalse(AmapShadowGate.shouldTriggerNewRequest(40_000L, 1_000L, inFlight = true))
        assertTrue(AmapShadowGate.shouldTriggerNewRequest(26_000L, 1_000L, inFlight = false))

        assertTrue(AmapShadowGate.isReusableCache(10_000L, 5_000L))
        assertFalse(AmapShadowGate.isReusableCache(20_000L, 5_000L))
    }

    @Test
    fun pairedRecordFormat_marksGcj02AndComputesSameDatumDistance() {
        val dist = AmapShadowGate.pairDistanceMeters(
            ok = true,
            nativeLatGcj = 31.2304,
            nativeLngGcj = 121.4737,
            amapLatGcj = 31.2305,
            amapLngGcj = 121.4737,
        )
        assertNotNull(dist)
        assertTrue(dist!! in 10.0..12.0)
        assertNull(AmapShadowGate.pairDistanceMeters(false, 31.2304, 121.4737, 31.2305, 121.4737))

        val line = AmapShadowGate.formatPairedJsonLine(
            trigger = "callback",
            nativeTsMs = 1_795_800_000_000L,
            nativeLatGcj = 31.2304,
            nativeLngGcj = 121.4737,
            nativeAcc = 18.5,
            nativeProvider = "gps",
            nativeSpeed = 0.2,
            nativeDebounce = "emit_move",
            nativeState = "MOVING",
            amapOk = true,
            amapTsMs = 1_795_800_000_800L,
            amapLatGcj = 31.2305,
            amapLngGcj = 121.4737,
            amapAcc = 12.0,
            amapLocType = 5,
            amapCoordType = "GCJ02",
            amapErrCode = 0,
            amapErrInfo = "",
        )
        assertTrue(line.contains("\"coord_sys\":\"GCJ-02\""))
        assertTrue(line.contains("\"amap_dt_ms\":800"))
        assertTrue(line.contains("\"amap_loc_type_name\":\"wifi\""))
        assertTrue(line.contains("\"amap_ok\":true"))
        assertEquals("gps", AmapShadowGate.locationTypeName(1))
        assertEquals("cell", AmapShadowGate.locationTypeName(6))
    }
}
