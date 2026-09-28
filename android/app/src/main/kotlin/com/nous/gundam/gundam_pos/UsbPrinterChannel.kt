package com.nous.gundam.gundam_pos

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Android USB Host transport for POS thermal printers, with the four common
 * serial bridge chips built in (see [UsbSerialDrivers]).
 *
 * Mirrors [BluetoothPrinterChannel]: every failure is a typed `{state, detail}`
 * map (never a thrown PlatformException), so a printer fault can never kill a
 * sale. `state` values map to `PrinterLinkState` on the Dart side:
 *   ready | offline | disconnected | permission_required | unsupported
 *
 * Requesting USB permission never blocks: the call answers immediately with
 * `permission_required` (or `ready` when already granted) and the OS dialog is
 * resolved asynchronously. A deny or a timeout is reported, never a crash.
 */
class UsbPrinterChannel(private val activity: Activity) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "gundam/printer/usb"
        const val ACTION_USB_PERMISSION = "com.nous.gundam.gundam_pos.USB_PERMISSION"
        const val DEFAULT_TIMEOUT_MS = 15_000
    }

    private val usbManager: UsbManager?
        get() = activity.getSystemService(Context.USB_SERVICE) as? UsbManager

    private var connection: UsbDeviceConnection? = null
    private var claimed: UsbInterface? = null
    private var outEndpoint: UsbEndpoint? = null

    @Volatile
    private var permissionReceiver: BroadcastReceiver? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "status" -> result.success(statusMap())
                "listDevices" -> result.success(listDevices())
                "hasPermission" -> result.success(hasPermission(call.argument<Int>("vid"), call.argument<Int>("pid")))
                "requestPermission" -> requestPermission(
                    call.argument<Int>("vid"),
                    call.argument<Int>("pid"),
                    call.argument<Int>("timeoutMs") ?: DEFAULT_TIMEOUT_MS,
                    result,
                )
                "open" -> open(
                    call.argument<Int>("vid"),
                    call.argument<Int>("pid"),
                    call.argument<String>("chip"),
                    call.argument<Int>("baud") ?: 9600,
                    result,
                )
                "write" -> write(call.argument<ByteArray>("bytes"), result)
                "close" -> {
                    closeInternal()
                    result.success(true)
                }
                "isConnected" -> result.success(connection != null && outEndpoint != null)
                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            // Belt and braces: an unexpected fault is still a typed result, not a crash.
            result.success(failure("unsupported", t.message))
        }
    }

    // --------------------------------------------------------------- status ---

    private fun statusMap(): Map<String, Any?> {
        val mgr = usbManager ?: return failure("unsupported", "USB host is not available on this device.")
        if (mgr.deviceList.isEmpty()) {
            return failure("offline", "No USB device attached.")
        }
        return mapOf("state" to "ready", "detail" to "${mgr.deviceList.size} USB device(s) attached.")
    }

    /** Every attached USB device with the chip this build would drive it with. */
    private fun listDevices(): List<Map<String, Any?>> {
        val mgr = usbManager ?: return emptyList()
        val out = ArrayList<Map<String, Any?>>()
        for (d in mgr.deviceList.values) {
            val driver = driverFor(d)
            out.add(
                mapOf(
                    "vid" to d.vendorId,
                    "pid" to d.productId,
                    "name" to (d.productName ?: d.deviceName),
                    "chip" to (driver?.id ?: ""),
                    "serial" to runCatching { d.serialNumber }.getOrNull(),
                    "granted" to mgr.hasPermission(d),
                ),
            )
        }
        return out
    }

    /** The driver for an attached device: by vendor/product id, else a CDC-ACM class match. */
    private fun driverFor(d: UsbDevice): UsbSerialDriver? =
        UsbSerialDrivers.driverFor(d.vendorId, d.productId) ?: if (isCdcAcm(d)) CdcAcmDriver else null

    /** True when any interface declares the CDC Communication class (0x02) or CDC-Data (0x0A). */
    private fun isCdcAcm(d: UsbDevice): Boolean {
        for (i in 0 until d.interfaceCount) {
            val cls = d.getInterface(i).interfaceClass
            if (cls == UsbConstants.USB_CLASS_COMM || cls == UsbConstants.USB_CLASS_CDC_DATA) return true
        }
        return false
    }

    // ------------------------------------------------------------- permission ---

    private fun findDevice(vid: Int?, pid: Int?): UsbDevice? {
        val mgr = usbManager ?: return null
        if (vid == null || pid == null) return mgr.deviceList.values.firstOrNull()
        return mgr.deviceList.values.firstOrNull { it.vendorId == vid && it.productId == pid }
    }

    private fun hasPermission(vid: Int?, pid: Int?): Boolean {
        val mgr = usbManager ?: return false
        val d = findDevice(vid, pid) ?: return false
        return mgr.hasPermission(d)
    }

    /**
     * Ask the OS for permission to open the printer and resolve with the user's
     * answer (`true`/`false`). The dialog is asynchronous; the call answers on
     * the broadcast or a timeout. Already-granted answers `true` immediately, so
     * an ordinary sale never waits on a dialog.
     */
    private fun requestPermission(vid: Int?, pid: Int?, timeoutMs: Int, result: MethodChannel.Result) {
        val mgr = usbManager ?: run {
            result.success(failure("unsupported", "USB host is not available on this device."))
            return
        }
        val device = findDevice(vid, pid) ?: run {
            result.success(failure("offline", "Configured USB printer is not attached."))
            return
        }
        if (mgr.hasPermission(device)) {
            result.success(true)
            return
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
        val intent = PendingIntent.getBroadcast(
            activity, 0, Intent(ACTION_USB_PERMISSION).setPackage(activity.packageName), flags,
        )
        try {
            mgr.requestPermission(device, intent)
        } catch (t: Throwable) {
            result.success(failure("offline", "Could not request USB permission: ${t.message}"))
            return
        }
        registerReceiver(timeoutMs, result)
    }

    /** Resolve [result] exactly once: on the OS broadcast, or on a deny/timeout. */
    private fun registerReceiver(timeoutMs: Int, result: MethodChannel.Result) {
        unregisterReceiver()
        val answered = java.util.concurrent.atomic.AtomicBoolean(false)
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action != ACTION_USB_PERMISSION) return
                unregisterReceiver()
                if (answered.compareAndSet(false, true)) {
                    result.success(intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false))
                }
            }
        }
        permissionReceiver = receiver
        val filter = IntentFilter(ACTION_USB_PERMISSION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            activity.registerReceiver(receiver, filter)
        }
        Handler(Looper.getMainLooper()).postDelayed({
            unregisterReceiver()
            if (answered.compareAndSet(false, true)) result.success(false) // denied / no answer
        }, timeoutMs.toLong())
    }

    private fun unregisterReceiver() {
        val r = permissionReceiver ?: return
        permissionReceiver = null
        runCatching { activity.unregisterReceiver(r) }
    }

    // ----------------------------------------------------------------- open ---

    private fun open(vid: Int?, pid: Int?, chip: String?, baud: Int, result: MethodChannel.Result) {
        val mgr = usbManager ?: run {
            result.success(failure("unsupported", "USB host is not available on this device."))
            return
        }
        val device = findDevice(vid, pid) ?: run {
            result.success(failure("offline", "Configured USB printer is not attached (check the cable / VID:PID)."))
            return
        }
        if (!mgr.hasPermission(device)) {
            result.success(failure("permission_required", "USB permission has not been granted."))
            return
        }
        val driver = UsbSerialDrivers.byId(chip)
        if (driver == null) {
            result.success(failure("unsupported", "Unsupported USB chip '${chip ?: "?"}'."))
            return
        }
        if (!driver.matches(device.vendorId, device.productId) && !(driver === CdcAcmDriver && isCdcAcm(device))) {
            result.success(
                failure(
                    "unsupported",
                    "Configured chip ${driver.id} does not match the attached device " +
                        "(%04X:%04X).".format(device.vendorId, device.productId),
                ),
            )
            return
        }

        // Claim + init block on control transfers; run off the platform thread.
        Thread {
            val outcome = openBlocking(mgr, device, driver, baud)
            activity.runOnUiThread { result.success(outcome) }
        }.start()
    }

    private fun openBlocking(mgr: UsbManager, device: UsbDevice, driver: UsbSerialDriver, baud: Int): Map<String, Any?> {
        closeInternal()
        val iface = findOutInterface(device)
            ?: return failure("offline", "No writable interface/endpoint on the USB printer.")
        val endpoint = iface.firstBulkOut()
            ?: return failure("offline", "No bulk OUT endpoint on the USB printer interface.")
        val conn = mgr.openDevice(device)
            ?: return failure("offline", "Could not open the USB device (kernel driver busy?).")
        if (!conn.claimInterface(iface, true)) {
            runCatching { conn.close() }
            return failure("offline", "Could not claim the USB interface (busy?).")
        }
        for (c in driver.initSequence(baud)) {
            conn.controlTransfer(c.requestType, c.request, c.value, c.index, c.data, c.data?.size ?: 0, 1000)
        }
        connection = conn
        claimed = iface
        outEndpoint = endpoint
        return mapOf(
            "state" to "ready",
            "detail" to "Opened ${driver.id} on %04X:%04X at $baud baud.".format(device.vendorId, device.productId),
        )
    }

    private fun findOutInterface(device: UsbDevice): UsbInterface? {
        for (i in 0 until device.interfaceCount) {
            val iface = device.getInterface(i)
            if (iface.firstBulkOut() != null) return iface
        }
        return null
    }

    private fun UsbInterface.firstBulkOut(): UsbEndpoint? {
        for (e in 0 until endpointCount) {
            val ep = getEndpoint(e)
            if (ep.type == UsbConstants.USB_ENDPOINT_XFER_BULK && ep.direction == UsbConstants.USB_DIR_OUT) return ep
        }
        return null
    }

    // ---------------------------------------------------------------- write ---

    private fun write(bytes: ByteArray?, result: MethodChannel.Result) {
        if (bytes == null || bytes.isEmpty()) {
            result.success(failure("offline", "No bytes to write."))
            return
        }
        val conn = connection
        val ep = outEndpoint
        if (conn == null || ep == null) {
            result.success(failure("disconnected", "USB printer is not open."))
            return
        }
        Thread {
            val outcome = try {
                val sent = conn.bulkTransfer(ep, bytes, bytes.size, 5000)
                if (sent < 0) {
                    closeInternal()
                    failure("disconnected", "USB bulk write failed (device removed?).")
                } else {
                    mapOf("state" to "ready", "detail" to "Wrote $sent bytes.")
                }
            } catch (t: Throwable) {
                closeInternal()
                failure("disconnected", "USB write failed: ${t.message}")
            }
            activity.runOnUiThread { result.success(outcome) }
        }.start()
    }

    private fun closeInternal() {
        val iface = claimed
        val conn = connection
        claimed = null
        connection = null
        outEndpoint = null
        if (conn != null) {
            if (iface != null) runCatching { conn.releaseInterface(iface) }
            runCatching { conn.close() }
        }
    }

    private fun failure(state: String, detail: String?): Map<String, Any?> =
        mapOf("state" to state, "detail" to (detail ?: state))
}
