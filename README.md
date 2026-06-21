# 🌍 Vibration-Based Earthquake Detection and Alert System

An IoT-based earthquake detection and alert system developed as an academic minor project using ESP32 and vibration sensors. The system continuously monitors ground vibrations and generates alerts when abnormal vibrations exceed predefined thresholds.

---

## 📌 Project Overview

This project aims to demonstrate how low-cost embedded systems can be used for early earthquake detection and awareness.

The system uses sensor data to detect unusual vibration patterns and trigger alerts, providing a simple and portable monitoring solution.

---

## 🎯 Objectives

- Monitor ground vibrations in real time.
- Detect abnormal vibration patterns.
- Generate alerts during possible seismic activities.
- Explore the application of IoT and embedded systems in disaster monitoring.

---

## 🛠️ Technologies Used

### Hardware
- ESP32 Development Board
- MPU6050 Accelerometer & Gyroscope Sensor
- Battery Supply

### Software
- Arduino IDE
- C++ (Arduino Framework)
- Flutter (Prototype Application)

---

## ⚙️ System Workflow

1. The vibration sensor continuously measures acceleration data.
2. The ESP32 processes the sensor readings.
3. The readings are compared with predefined threshold values.
4. If abnormal vibrations are detected, an alert is triggered.

---

## 📂 Repository Contents

```
├── Node1.ino                  # Source code for Node 1
├── Node2.ino                  # Source code for Node 2
├── pcb.png                    # PCB design/image
├── vbedas_app_prototype.dart  # Flutter application prototype
├── vbedas_report.pdf          # Complete project documentation
└── README.md
```

---

## 📷 Project Resources

- 📄 Complete Documentation: `vbedas_report.pdf`
- 🖼️ PCB Design: `pcb.png`
- 💻 Firmware:
  - `Node1.ino`
  - `Node2.ino`
- 📱 Flutter Prototype:
  - `vbedas_app_prototype.dart`

---

## 🔮 Future Improvements

- Mobile notifications for alerts.
- Cloud-based monitoring dashboard.
- Multiple sensor nodes for improved accuracy.
- Machine learning techniques for vibration classification.
- Improved power management and portability.

---

## 👨‍💻 Authors

Developed as a Minor Project by:

- Sujan Raj Regmi
- Shashank Singh
- Kushal Pokhrel
- Mausham Kadariya

---

## 📄 License

This repository is shared for educational and research purposes.

Feel free to fork, modify, and improve the project.
