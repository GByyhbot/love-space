package cn.iepose.lovespace.love_space

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaceFormatterTest {
    @Test
    fun formatsChineseCityDistrictStreetWithoutDuplicates() {
        val name = PlaceFormatter.formatAddress(
            adminArea = "上海市",
            locality = "上海市",
            subLocality = "浦东新区",
            thoroughfare = "张江路",
            featureName = "18号",
            addressLine = "中国上海市浦东新区张江路18号",
        )
        assertEquals("上海市浦东新区张江路", name)
    }

    @Test
    fun usesAdminAreaWhenLocalityMissingAndFeatureWhenStreetMissing() {
        val name = PlaceFormatter.formatAddress(
            adminArea = "北京市",
            locality = null,
            subLocality = "海淀区",
            thoroughfare = null,
            featureName = "中关村软件园",
            addressLine = null,
        )
        assertEquals("北京市海淀区中关村软件园", name)
    }

    @Test
    fun dropsPureNumericOrCountryOnlyAndTruncatesAt24Chars() {
        assertEquals(
            "",
            PlaceFormatter.formatAddress(
                adminArea = "中国",
                locality = null,
                subLocality = null,
                thoroughfare = null,
                featureName = "12345",
                addressLine = "中国",
            ),
        )
        val longName = PlaceFormatter.formatAddress(
            adminArea = "广东省",
            locality = "深圳市",
            subLocality = "南山区高新科技园北区",
            thoroughfare = "科技中一路非常长的一条道路名称测试超出长度",
            featureName = null,
            addressLine = null,
        )
        assertEquals(24, longName.length)
    }

    @Test
    fun fallsBackToAddressLineStrippingChinaPrefix() {
        val name = PlaceFormatter.formatAddress(
            adminArea = null,
            locality = null,
            subLocality = null,
            thoroughfare = null,
            featureName = null,
            addressLine = "中国江苏省苏州市工业园区",
        )
        assertEquals("江苏省苏州市工业园区", name)
    }

    @Test
    fun shouldRegeocodeThrottlesUnder150MetersAnd10Minutes() {
        val baseLat = 31.2304
        val baseLng = 121.4737
        assertTrue(PlaceFormatter.shouldRegeocode(null, null, 0L, baseLat, baseLng, 1000L))
        // ~11 meters away, 1 minute later -> skip
        assertFalse(
            PlaceFormatter.shouldRegeocode(
                baseLat,
                baseLng,
                1000L,
                baseLat + 0.0001,
                baseLng,
                61_000L,
            ),
        )
        // ~222 meters away, 1 minute later -> regeocode
        assertTrue(
            PlaceFormatter.shouldRegeocode(
                baseLat,
                baseLng,
                1000L,
                baseLat + 0.002,
                baseLng,
                61_000L,
            ),
        )
        // Same point, 10 minutes later -> regeocode
        assertTrue(
            PlaceFormatter.shouldRegeocode(
                baseLat,
                baseLng,
                1000L,
                baseLat,
                baseLng,
                1000L + 10 * 60_000L,
            ),
        )
    }
}
