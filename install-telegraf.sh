#!/bin/sh

set -eu

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SYSTEMD_DIR="$HOME/.config/systemd/user"
CONTAINERS_DIR="$HOME/containers"

echo "Instalando Telegraf..."

echo "Creando directorio de contenedores en $CONTAINERS_DIR..."
mkdir -p "$CONTAINERS_DIR"

echo "Descargando contenedor de Telegraf..."
apptainer build "$CONTAINERS_DIR/telegraf.sif" docker://telegraf:latest

echo "Copiando configuración de Telegraf..."
cp -r "$REPO_DIR/telegraf" "$CONTAINERS_DIR/telegraf"

echo "Copiando plantilla de entorno..."
cp "$REPO_DIR/telegraf.env" "$CONTAINERS_DIR/telegraf.env"

echo "Instalando servicio systemd de usuario..."

mkdir -p "$SYSTEMD_DIR"

echo "Copiando archivo de servicio de Telegraf..."
cp "$REPO_DIR/systemd/telegraf.service" "$SYSTEMD_DIR/"

echo "Recargando systemd..."
systemctl --user daemon-reload

echo "Habilitando telegraf.service..."
systemctl --user enable telegraf.service

echo "Activando linger para arranque automático..."
loginctl enable-linger "$(whoami)" 2>/dev/null || true

echo ""
echo "Instalación completada."
echo "Inicia Telegraf con:"
echo "  systemctl --user start telegraf.service"
