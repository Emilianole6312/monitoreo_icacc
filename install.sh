#!/bin/sh

set -eu

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SYSTEMD_DIR="$HOME/.config/systemd/user"
CONTAINERS_DIR="$HOME/containers"

echo "Instalando stack de monitoreo."
echo "Creando directorio de contenedores en $CONTAINERS_DIR..."
mkdir -p "$CONTAINERS_DIR"

echo "Creando contenedores..."
echo "Descargando contenedor de InfluxDB..."
apptainer pull $CONTAINERS_DIR/influxdb.sif docker://influxdb:latest

echo "Descargando contenedor de Grafana..."
apptainer build $CONTAINERS_DIR/grafana.sif docker://grafana/grafana-oss:latest

echo "Descargando contenedor de telegraf..."
apptainer build $CONTAINERS_DIR/telegraf.sif docker://telegraf:latest

echo "Copiando archivos de configuración..."
cp -r "$REPO_DIR/influxdb" "$CONTAINERS_DIR/influxdb"
cp -r "$REPO_DIR/grafana" "$CONTAINERS_DIR/grafana"
cp -r "$REPO_DIR/telegraf" "$CONTAINERS_DIR/telegraf"

echo "Copiando plantillas de .env..."
cp "$REPO_DIR/grafana.env" "$CONTAINERS_DIR/grafana.env"
cp "$REPO_DIR/telegraf.env" "$CONTAINERS_DIR/telegraf.env"

echo "Instalando servicios systemd de usuario..."

mkdir -p "$SYSTEMD_DIR"

echo "Copiando archivos de servicio..."
cp "$REPO_DIR/systemd/"*.service "$SYSTEMD_DIR/"
cp "$REPO_DIR/systemd/"*.target "$SYSTEMD_DIR/"

echo "Recargando systemd..."
systemctl --user daemon-reload

echo "Habilitando monitoring.target..."
systemctl --user enable monitoring.target

echo "Activando linger para arranque automático..."
loginctl enable-linger "$(whoami)" 2>/dev/null || true

echo ""
echo "Instalación completada."
echo "Sigue las instrucciones en el README para configurar InfluxDB, Grafana y Telegraf."
echo "Inicia el stack con:"
echo "  systemctl --user start monitoring.target"