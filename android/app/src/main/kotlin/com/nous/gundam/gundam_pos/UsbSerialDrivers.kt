package com.nous.gundam.gundam_pos

/**
 * USB-serial bridge-chip drivers built INTO the APK — no separate driver app.
 *
 * Each chip is described as pure data + small pure functions:
 *   * [matches]      — how the chip is recognised on the bus (vendor/product id);
 *   * [initSequence] — the USB control-transfer sequence that brings the chip up
 *                      for 8N1 at a given baud (line coding, and for FTDI the
 *                      baud divisor + latency timer).
 *
 * [UsbPrinterChannel] claims the interface and replays [initSequence] over a
 * real [android.hardware.usb.UsbDeviceConnection], then writes with bulk OUT.
 *
 * WHY PURE / WHY HERE: the Kotlin side cannot be unit-tested off a device, so
 * the init logic lives here as data a reviewer can read line by line. Everything
 * in this file is verified ONLY by inspection plus the Dart-side tests; a real
 * end-to-end check needs a physical printer attached to a real Android host.
 */

/** One USB control transfer: bmRequestType, bRequest, wValue, wIndex, optional data. */
class UsbControl(
    val requestType: Int,
    val request: Int,
    val value: Int,
    val index: Int,
    val data: ByteArray? = null,
)

// bmRequestType helpers (direction | type | recipient).
private const val HOST_TO_DEVICE_VENDOR = 0x40 // out | vendor | device
private const val HOST_TO_DEVICE_CLASS = 0x21 // out | class  | interface

/** Supported chip ids — the exact strings the web `usbChip` field is expected to send. */
object UsbChipIds {
    const val CDC_ACM = "CDC_ACM"
    const val CH340 = "CH340"
    const val PL2303 = "PL2303"
    const val FTDI = "FTDI"

    /** Canonicalise a configured chip string (tolerant of aliases / casing). */
    fun canonical(raw: String?): String? {
        val v = (raw ?: "").trim().uppercase().replace('-', '_').replace(' ', '_')
        return when (v) {
            "", "AUTO", "ANY" -> null
            "CDC", "CDCACM", "ACM", "CDC_ACM" -> CDC_ACM
            "CH340", "CH341", "CH340G", "CH341A", "CH34X" -> CH340
            "PL2303", "PL2303HX", "PL2303HXA", "PROLIFIC" -> PL2303
            "FTDI", "FT232", "FT232R", "FT231", "FT231X", "FTDI_FT232R" -> FTDI
            else -> v
        }
    }
}

interface UsbSerialDriver {
    /** Canonical chip id (see [UsbChipIds]). */
    val id: String

    /** True when this driver recognises the attached device by vendor/product id. */
    fun matches(vendorId: Int, productId: Int): Boolean

    /** The control-transfer sequence that prepares the chip for 8N1 at [baud]. */
    fun initSequence(baud: Int): List<UsbControl>
}

/**
 * Generic CDC-ACM (USB Communications Device Class, subclass ACM 0x02).
 * Matched by the interface class in [UsbPrinterChannel] (a device exposing a
 * class-0x02/0x0A interface) plus the known vendor ids below.
 *
 * Init = the standard CDC line-coding + control-line-state pair (Linux cdc_acm):
 *   1. SET_LINE_CODING  (0x20, class/interface): 7-byte dwDTERate/bCharFormat/
 *      bParityType/bDataBits — little-endian baud, 1 stop, no parity, 8 bits;
 *   2. SET_CONTROL_LINE_STATE (0x22): wValue 0x03 = DTR|RTS asserted.
 */
object CdcAcmDriver : UsbSerialDriver {
    override val id = UsbChipIds.CDC_ACM

    // Common CDC-ACM serial vendors (Arduino/STM32/Espressif/Adafruit/LeafLabs).
    private val vids = setOf(
        0x2341, // Arduino SA
        0x2A03, // Arduino LLC
        0x1A86, // WCH CH9102 (CDC variant) — CH340/CH341 matched by Ch34xDriver first
        0x0483, // STMicroelectronics (STM32 Virtual COM Port)
        0x303A, // Espressif (Espressif USB Serial/JTAG)
        0x1EAF, // LeafLabs
        0x239A, // Adafruit
        0x1915, // Nordic
        0x1209, // pid.codes (interchangeable USB)
    )

    override fun matches(vendorId: Int, productId: Int): Boolean = vendorId in vids

    override fun initSequence(baud: Int): List<UsbControl> {
        val rate = baud.coerceIn(300, 4_000_000)
        val lineCoding = byteArrayOf(
            (rate and 0xFF).toByte(),
            ((rate shr 8) and 0xFF).toByte(),
            ((rate shr 16) and 0xFF).toByte(),
            ((rate shr 24) and 0xFF).toByte(),
            0x00, // bCharFormat: 1 stop bit
            0x00, // bParityType: none
            0x08, // bDataBits: 8
        )
        return listOf(
            UsbControl(HOST_TO_DEVICE_CLASS, 0x20, 0x0000, 0x0000, lineCoding), // SET_LINE_CODING
            UsbControl(HOST_TO_DEVICE_CLASS, 0x22, 0x0003, 0x0000, null), // SET_CONTROL_LINE_STATE DTR|RTS
        )
    }
}

/**
 * WCH CH340 / CH341 USB-serial.
 *   Vendor  0x1A86
 *   Products 0x7523 (CH340), 0x5523 (CH341A), 0x7522 (CH341), 0x55D4 (CH9102)
 *
 * Init = the kernel `ch341.c` sequence (register writes over request 0x9A):
 *   1. serial init               (0xA1, wValue 0x0000, wIndex 0x0000);
 *   2. baud divisor low          (reg 0x1312 ← divisor&0xFF);
 *   3. baud divisor high         (reg 0x0F2C ← divisor>>8);
 *   4. line control LCR          (reg 0x2518 ← 0xC3 = RX/TX enable + 8N1);
 *   5. modem control             (0xA4, DTR/RTS asserted).
 * The divisor table is the CH340 datasheet table for the 12 MHz crystal.
 */
object Ch34xDriver : UsbSerialDriver {
    override val id = UsbChipIds.CH340

    private const val VID = 0x1A86
    private val pids = setOf(0x7523, 0x5523, 0x7522, 0x55D4)

    private const val REQ_WRITE_REG = 0x9A
    private const val REQ_SERIAL_INIT = 0xA1
    private const val REQ_MODEM_CTRL = 0xA4

    // CH340 datasheet divisor table (12 MHz). baud → (low, high) register bytes.
    private val divisors: List<Pair<Int, Int>> = listOf(
        2400 to 0xD901, 4800 to 0x6402, 9600 to 0x1F02, 19200 to 0x0F02,
        38400 to 0x0702, 57600 to 0x0502, 115200 to 0x0402, 230400 to 0x0202,
        460800 to 0x0102, 921600 to 0x0080,
    )

    override fun matches(vendorId: Int, productId: Int): Boolean = vendorId == VID && productId in pids

    override fun initSequence(baud: Int): List<UsbControl> {
        val divisor = divisors.firstOrNull { it.first == baud }?.second
        // Fallback for an unlisted baud: 12_000_000 / baud (documented approximation).
            ?: (12_000_000 / baud.coerceAtLeast(300)).coerceIn(0, 0xFFFF)
        val low = divisor and 0xFF
        val high = (divisor shr 8) and 0xFF
        return listOf(
            UsbControl(HOST_TO_DEVICE_VENDOR, REQ_SERIAL_INIT, 0x0000, 0x0000, null),
            UsbControl(HOST_TO_DEVICE_VENDOR, REQ_WRITE_REG, 0x1312, low, null),
            UsbControl(HOST_TO_DEVICE_VENDOR, REQ_WRITE_REG, 0x0F2C, high, null),
            UsbControl(HOST_TO_DEVICE_VENDOR, REQ_WRITE_REG, 0x2518, 0xC3, null), // LCR: 8N1 + enable
            UsbControl(HOST_TO_DEVICE_VENDOR, REQ_MODEM_CTRL, 0x0000, 0x0000, null), // DTR/RTS
        )
    }
}

/**
 * Prolific PL2303 (HX / HXA variants).
 *   Vendor  0x067B
 *   Products 0x2303 (H/HX/HXA), 0x2304, 0x23A3, 0x23B3, 0x23C3, 0x23D3, 0x23E3, 0x23F3
 *
 * Init:
 *   1. HX/HXA reset              (vendor request 0x01, wValue 0x0404, 8-byte magic);
 *   2. SET_LINE_CODING  (0x20):  dwDTERate/bCharFormat/bParityType/bDataBits (8N1);
 *   3. SET_CONTROL_LINE_STATE (0x22): wValue 0x03 = DTR|RTS.
 */
object Pl2303Driver : UsbSerialDriver {
    override val id = UsbChipIds.PL2303

    private const val VID = 0x067B
    private val pids = setOf(0x2303, 0x2304, 0x23A3, 0x23B3, 0x23C3, 0x23D3, 0x23E3, 0x23F3)

    private const val REQ_VENDOR_WRITE = 0x01
    private const val REQ_SET_LINE_CODING = 0x20
    private const val REQ_SET_CONTROL_LINE_STATE = 0x22

    // HX/HXA power-on magic (documented pl2303 HX reset byte run).
    private val hxReset = byteArrayOf(0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)

    override fun matches(vendorId: Int, productId: Int): Boolean = vendorId == VID && productId in pids

    override fun initSequence(baud: Int): List<UsbControl> {
        val rate = baud.coerceIn(300, 6_000_000)
        val lineCoding = byteArrayOf(
            (rate and 0xFF).toByte(),
            ((rate shr 8) and 0xFF).toByte(),
            ((rate shr 16) and 0xFF).toByte(),
            ((rate shr 24) and 0xFF).toByte(),
            0x00, // 1 stop
            0x00, // no parity
            0x08, // 8 data bits
        )
        return listOf(
            UsbControl(HOST_TO_DEVICE_VENDOR, REQ_VENDOR_WRITE, 0x0404, 0x0000, hxReset),
            UsbControl(HOST_TO_DEVICE_CLASS, REQ_SET_LINE_CODING, 0x0000, 0x0000, lineCoding),
            UsbControl(HOST_TO_DEVICE_CLASS, REQ_SET_CONTROL_LINE_STATE, 0x0003, 0x0000, null),
        )
    }
}

/**
 * FTDI FT232R / FT231X (and the FT232H family).
 *   Vendor  0x0403
 *   Products 0x6001 (FT232R), 0x6015 (FT231X/X), 0x6014 (FT232H),
 *            0x6010 (FT2232H), 0x6011 (FT4232H)
 *
 * Init (libftdi order):
 *   1. SIO_RESET       (0x00, wValue 0)        — reset the port;
 *   2. SIO_SET_BAUD_RATE (0x03): wValue = divisor, wIndex high byte = sub-divisor
 *      (FT232R: base 3 MHz, divisor = 3_000_000/baud, sub = round(frac*8));
 *   3. SIO_SET_DATA    (0x04, wValue 0x0008)   — 8 data bits, 1 stop, no parity;
 *   4. SIO_SET_FLOW_CTRL (0x02, wValue 0x0000) — RTS/CTS off;
 *   5. SIO_SET_LATENCY_TIMER (0x09, wValue 16);
 *   6. SIO_SET_MODEM_CTRL (0x01, wValue 0x0303) — DTR + RTS.
 */
object FtdiDriver : UsbSerialDriver {
    override val id = UsbChipIds.FTDI

    private const val VID = 0x0403
    private val pids = setOf(0x6001, 0x6015, 0x6014, 0x6010, 0x6011)

    private const val SIO_RESET = 0x00
    private const val SIO_SET_MODEM_CTRL = 0x01
    private const val SIO_SET_FLOW_CTRL = 0x02
    private const val SIO_SET_BAUD_RATE = 0x03
    private const val SIO_SET_DATA = 0x04
    private const val SIO_SET_LATENCY_TIMER = 0x09

    override fun matches(vendorId: Int, productId: Int): Boolean = vendorId == VID && productId in pids

    /** FT232R baud divisor + sub-divisor encoding ([value, index]). */
    fun baudDivisor(baud: Int): Pair<Int, Int> {
        val rate = baud.coerceIn(300, 3_000_000)
        val exact = 3_000_000.0 / rate
        var divisor = exact.toInt()
        var sub = Math.round((exact - divisor) * 8.0).toInt()
        if (sub == 8) {
            divisor += 1
            sub = 0
        }
        // wValue = divisor (16 bit); wIndex low nibble of the high byte = sub-divisor.
        return (divisor and 0xFFFF) to ((sub and 0x07) shl 8)
    }

    override fun initSequence(baud: Int): List<UsbControl> {
        val (value, index) = baudDivisor(baud)
        return listOf(
            UsbControl(HOST_TO_DEVICE_VENDOR, SIO_RESET, 0x0000, 0x0000, null),
            UsbControl(HOST_TO_DEVICE_VENDOR, SIO_SET_BAUD_RATE, value, index, null),
            UsbControl(HOST_TO_DEVICE_VENDOR, SIO_SET_DATA, 0x0008, 0x0000, null),
            UsbControl(HOST_TO_DEVICE_VENDOR, SIO_SET_FLOW_CTRL, 0x0000, 0x0000, null),
            UsbControl(HOST_TO_DEVICE_VENDOR, SIO_SET_LATENCY_TIMER, 16, 0x0000, null),
            UsbControl(HOST_TO_DEVICE_VENDOR, SIO_SET_MODEM_CTRL, 0x0303, 0x0000, null),
        )
    }
}

/** The four chips built into this APK, in match-priority order. */
object UsbSerialDrivers {
    val all: List<UsbSerialDriver> = listOf(Ch34xDriver, Pl2303Driver, FtdiDriver, CdcAcmDriver)

    fun byId(id: String?): UsbSerialDriver? {
        val c = UsbChipIds.canonical(id) ?: return null
        return all.firstOrNull { it.id == c }
    }

    /** The driver recognising a device by vendor/product id (CDC-ACM last, as a class fallback). */
    fun driverFor(vendorId: Int, productId: Int): UsbSerialDriver? =
        all.firstOrNull { it.matches(vendorId, productId) }
}
