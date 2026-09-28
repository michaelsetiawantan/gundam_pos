package com.nous.gundam.gundam_pos

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothSocket
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

/**
 * Classic Bluetooth SPP/RFCOMM transport for the POS thermal printers.
 *
 * Every failure is returned as a typed `{state, detail}` map (never a thrown
 * PlatformException) so a printer fault can never kill a sale. `state` values
 * mirror the PRD printer-status set and are mapped to `PrinterLinkState` on the
 * Dart side:
 *   ready | offline | disconnected | not_paired | bluetooth_off |
 *   permission_required | unsupported
 */
class BluetoothPrinterChannel(private val activity: Activity) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "gundam/printer"
        val SPP_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
        const val REQ_CONNECT = 0x4711
    }

    private var socket: BluetoothSocket? = null

    @Volatile
    private var lastConnectError: Throwable? = null

    private var pendingPermission: MethodChannel.Result? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "status" -> result.success(statusMap())
                "listBonded" -> result.success(listBonded())
                "requestPermission" -> requestPermission(result)
                "connect" -> connect(call.argument<String>("mac"), call.argument<Int>("timeoutMs") ?: 8000, result)
                "write" -> write(call.argument<ByteArray>("bytes"), result)
                "close" -> {
                    closeInternal()
                    result.success(true)
                }
                "isConnected" -> result.success(socket?.isConnected == true)
                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            // Belt and braces: an unexpected fault is still a typed result, not a crash.
            result.success(failure("unsupported", t.message))
        }
    }

    /** Forwarded from the Activity so a runtime permission prompt can answer. */
    fun onPermissionResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != REQ_CONNECT) return
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingPermission?.success(granted)
        pendingPermission = null
    }

    // --------------------------------------------------------------- status ---

    private fun adapter(): BluetoothAdapter? = BluetoothAdapter.getDefaultAdapter()

    private fun hasPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true // install-time grant
        val perm = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            Manifest.permission.BLUETOOTH_CONNECT
        } else {
            Manifest.permission.BLUETOOTH
        }
        return activity.checkSelfPermission(perm) == PackageManager.PERMISSION_GRANTED
    }

    private fun statusMap(): Map<String, Any?> {
        val a = adapter() ?: return failure("unsupported", "No Bluetooth adapter on this device.")
        if (!hasPermission()) {
            return failure("permission_required", "Bluetooth permission has not been granted.")
        }
        return try {
            if (a.isEnabled) mapOf("state" to "ready", "detail" to "Bluetooth is on.") else failure("bluetooth_off", "Bluetooth is switched off.")
        } catch (se: SecurityException) {
            failure("permission_required", se.message ?: "Bluetooth permission missing.")
        }
    }

    @SuppressLint("MissingPermission")
    private fun listBonded(): List<Map<String, Any?>> {
        val a = adapter() ?: return emptyList()
        if (!hasPermission()) return emptyList()
        val out = ArrayList<Map<String, Any?>>()
        try {
            for (d in a.bondedDevices) {
                out.add(mapOf("name" to (d.name ?: d.address), "mac" to d.address))
            }
        } catch (_: Throwable) {
            // Unreadable bonded list → empty, never a crash.
        }
        return out
    }

    // ------------------------------------------------------------ permission ---

    private fun requestPermission(result: MethodChannel.Result) {
        // Pre-12 the permission is install-time; nothing to prompt for.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            result.success(hasPermission())
            return
        }
        if (hasPermission()) {
            result.success(true)
            return
        }
        pendingPermission = result
        activity.requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT), REQ_CONNECT)
    }

    // --------------------------------------------------------------- connect ---

    private fun connect(mac: String?, timeoutMs: Int, result: MethodChannel.Result) {
        if (mac.isNullOrEmpty()) {
            result.success(failure("not_paired", "No bonded printer MAC is configured."))
            return
        }
        val a = adapter()
        if (a == null) {
            result.success(failure("unsupported", "No Bluetooth adapter on this device."))
            return
        }
        if (!hasPermission()) {
            result.success(failure("permission_required", "Bluetooth permission has not been granted."))
            return
        }
        try {
            if (!a.isEnabled) {
                result.success(failure("bluetooth_off", "Bluetooth is switched off."))
                return
            }
        } catch (se: SecurityException) {
            result.success(failure("permission_required", se.message ?: "Bluetooth permission missing."))
            return
        }

        // SPP connect blocks; run off the platform thread and answer on the UI thread.
        Thread {
            val outcome = connectBlocking(a, mac, timeoutMs)
            activity.runOnUiThread { result.success(outcome) }
        }.start()
    }

    @SuppressLint("MissingPermission")
    private fun connectBlocking(a: BluetoothAdapter, mac: String, timeoutMs: Int): Map<String, Any?> {
        val device: BluetoothDevice = try {
            a.getRemoteDevice(mac)
        } catch (t: Throwable) {
            return failure("not_paired", "Unknown device $mac.")
        }
        if (device.bondState != BluetoothDevice.BOND_BONDED) {
            return failure("not_paired", "$mac is not paired with this device.")
        }
        closeInternal()

        val s: BluetoothSocket = try {
            device.createRfcommSocketToServiceRecord(SPP_UUID)
        } catch (t: Throwable) {
            return failure("offline", "Could not open SPP socket: ${t.message}")
        }
        try {
            a.cancelDiscovery()
        } catch (_: Throwable) {
        }

        lastConnectError = null
        val worker = Thread {
            try {
                s.connect()
            } catch (t: Throwable) {
                lastConnectError = t
            }
        }
        worker.start()
        worker.join(timeoutMs.toLong())
        if (worker.isAlive) {
            // Still blocking after the timeout → cancel the socket and report it.
            try {
                s.close()
            } catch (_: Throwable) {
            }
            return failure("offline", "Connect to $mac timed out after ${timeoutMs}ms.")
        }
        if (!s.isConnected) {
            try {
                s.close()
            } catch (_: Throwable) {
            }
            val err = lastConnectError
            if (err is SecurityException) return failure("permission_required", err.message ?: "Bluetooth permission missing.")
            return failure("offline", "Could not connect to $mac (${err?.message ?: "socket refused"}). Is the printer on?")
        }
        socket = s
        return mapOf("state" to "ready", "detail" to "Connected to $mac over SPP.")
    }

    // ----------------------------------------------------------------- write ---

    private fun write(bytes: ByteArray?, result: MethodChannel.Result) {
        if (bytes == null) {
            result.success(failure("offline", "No bytes to write."))
            return
        }
        val s = socket
        if (s == null || !s.isConnected) {
            result.success(failure("disconnected", "Printer is not connected."))
            return
        }
        Thread {
            val outcome = try {
                s.outputStream.write(bytes)
                s.outputStream.flush()
                mapOf("state" to "ready", "detail" to "Wrote ${bytes.size} bytes.")
            } catch (t: Throwable) {
                closeInternal()
                failure("disconnected", "Write failed: ${t.message}")
            }
            activity.runOnUiThread { result.success(outcome) }
        }.start()
    }

    private fun closeInternal() {
        val s = socket ?: return
        socket = null
        try {
            s.close()
        } catch (_: Throwable) {
        }
    }

    private fun failure(state: String, detail: String?): Map<String, Any?> =
        mapOf("state" to state, "detail" to (detail ?: state))
}
