## **ColorCalibrate**
**Pro-grade display calibration. No extra hardware required.**

Inspired by Apple’s seamless "Color Balance" for Apple TV, **ColorCalibrate** brings effortless, device-independent color correction to your Mac devices. By using your iPhone’s ambient light sensor (via SensorKit) to measure your Mac’s display, ColorCalibrate bridges the gap between "eye-balling it" and buying expensive external hardware.

### **Why ColorCalibrate?**
Professional calibrators are bulky and expensive. ColorCalibrate turns the high-precision sensors already in your pocket into a measurement tool, ensuring your Mac’s white point and primaries are spot-on—whether you're editing photos or just want a more comfortable viewing experience.

### **Core Features**
*   **Dual-Platform Synergy:** A macOS desktop app drives the process while your iPhone acts as the high-precision light probe.
*   **True Device-Independence:** Targets are defined using **CIE xyY chromaticity coordinates** (D65 white point/Display P3). We don't just "guess" colors; we calculate precise $\Delta E$ comparisons in CIELAB space.
*   **Intelligent HDR/SDR Detection:** The app automatically senses your display’s current mode (SDR or EDR/HDR) and applies the correct calibration profile accordingly.
*   **Two Ways to Work:**
    *   **Calibration Mode:** A full automated sequence (White, RGB, Grayscale) to build a custom profile.
    *   **Measurement Mode:** A quick "health check" to see your current $\Delta E$ and verify how much your profile is improving the image.
*   **Safe & Reversible:** We use Core Graphics gamma tables to apply corrections, meaning you can restore your original factory settings with a single click.

### **How it Works**
1.  **Connect:** Link your Mac and iPhone instantly via **MultipeerConnectivity**.
2.  **Measure:** Hold your iPhone to the screen. The Mac flashes a sequence of color patches, and the iPhone’s sensor captures the light data in real-time.
3.  **Correct:** ColorCalibrate computes the necessary gains and offsets, generating a custom profile that aligns your screen to industry-standard targets.
