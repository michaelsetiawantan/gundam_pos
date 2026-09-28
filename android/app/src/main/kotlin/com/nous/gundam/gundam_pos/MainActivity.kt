package com.nous.gundam.gundam_pos

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var bluetooth: BluetoothPrinterChannel? = null
    private var usb: UsbPrinterChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val bt = BluetoothPrinterChannel(this)
        bluetooth = bt
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BluetoothPrinterChannel.CHANNEL)
            .setMethodCallHandler(bt)

        // USB Host transport — the four common bridge chips are built into the APK.
        val usbChannel = UsbPrinterChannel(this)
        usb = usbChannel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, UsbPrinterChannel.CHANNEL)
            .setMethodCallHandler(usbChannel)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        bluetooth?.onPermissionResult(requestCode, grantResults)
        // USB permission is granted by the OS dialog via a broadcast
        // (UsbManager.requestPermission) — no runtime-permission callback here.
    }
}
