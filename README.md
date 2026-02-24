# Modbus Multi-Session ICS Client (Mobile Edition)

A native iOS and Android application built with Flutter for connecting to, reading from, and writing to Modbus-enabled industrial control system (ICS) devices over a TCP/IP network.

Designed as a mobile companion to the desktop tool `modbus_gui_multi`, this app supports multiple simultaneous connections, automated background polling, sequential multi-address writes, and a format converter utility.

## Features
* **Multi-Session Architecture:** Connect to an unlimited number of PLCs simultaneously over TCP/IP.
* **Continuous Background Polling:** Start read or write loops that run on fixed intervals. The application enforces a minimum safety interval of 0.1s to prevent network spin-locking.
* **Multi-Address Write:** Queue up writes to disparate addresses (e.g., Holding Registers and Coils) and fire them sequentially in a single batch.
* **Dual Logging:** * *Session Log:* Tracks the last 500 events specific to an active connection.
    * *Global Log:* Aggregates and tags events from all active sessions simultaneously for easy monitoring.
* **Format Converter:** Instantly convert values between Decimal, Hexadecimal, and Binary.

## Prerequisites
* Flutter SDK (>=3.0.0)
* A physical Android or iOS device connected to the same WiFi/VPN network as your Modbus devices.

## Installation & Setup
1. Create a new flutter project: 
   ```bash
   flutter create modbus_app
