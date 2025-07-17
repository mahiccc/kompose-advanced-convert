Docker Compose to Kubernetes Converter
This project provides a tool to convert Docker Compose files into Kubernetes manifests using Kompose, with advanced features to detect config files, keys, and certificates and convert them into ConfigMaps and Secrets.

Features
Uses Kompose for base conversion
Detects .ini, .conf files and converts them to ConfigMaps
Detects .key, .crt, .pem files and converts them to Secrets
Avoids using PersistentVolumes for configs
Modular output structure for Kubernetes manifests