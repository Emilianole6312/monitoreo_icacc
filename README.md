# Monitoreo de cluster HPC con InfluxDB, Grafana y Telegraf  
  
# Resumen  
  
Este proyecto implementa un sistema de monitoreo para un cluster HPC utilizando **InfluxDB**, **Grafana** y **Telegraf**, desplegados mediante contenedores **Apptainer**.  
  
El sistema recolecta métricas de:  
  
- uso de CPU  
- memoria  
- disco  
- temperatura de PDUs mediante SNMP  
  
Las métricas son almacenadas en **InfluxDB** y visualizadas mediante **dashboards en Grafana**.  
  
El despliegue está automatizado mediante **systemd user services**, permitiendo ejecutar los servicios sin privilegios de administrador.  
  
---  
  
# Arquitectura  

Nodos HPC  
│  
│ métricas (CPU, memoria, disco)  
│ SNMP (temperatura PDU)  
▼  
Telegraf  
│  
▼  
InfluxDB  
│  
▼  
Grafana

  
---  
  
# Tecnologías utilizadas  
  
- Apptainer  
- InfluxDB  
- Grafana  
- Telegraf  
- SNMP  
- systemd (user services)  
  
---  
  
# Instalación  
  
Este repositorio incluye un **script de instalación** que realiza automáticamente los siguientes pasos:  
  
1. Crea el directorio `~/containers`  
2. Descarga los contenedores necesarios  
3. Copia archivos de configuración  
4. Instala los servicios de systemd  
5. Habilita los servicios mediante `monitoreo.target`  
6. Activa `linger` para permitir ejecución sin sesión iniciada  
  
Estructura creada:  
```
~/containers  
├── influxdb  
│ ├── data  
│ └── conf  
├── grafana  
│ ├── data  
│ └── provisioning  
└── telegraf  
├── telegraf.conf  
└── telegraf.d
```
  
Una vez instalado el sistema los servicios pueden iniciarse con:  
  
```bash  
systemctl --user start monitoreo.target
```

---

# Configuración

## InfluxDB

Inicializar InfluxDB con variables de entorno:
```
apptainer run \  
--bind ~/containers/influxdb/data:/var/lib/influxdb2 \  
--bind ~/containers/influxdb/conf:/etc/influxdb2 \  
--env DOCKER_INFLUXDB_INIT_MODE=setup \  
--env DOCKER_INFLUXDB_INIT_USERNAME=<ADMIN_USER> \  
--env DOCKER_INFLUXDB_INIT_PASSWORD=<ADMIN_PASSWORD> \  
--env DOCKER_INFLUXDB_INIT_ORG=icacc \  
--env DOCKER_INFLUXDB_INIT_BUCKET=monitoreo \  
--env DOCKER_INFLUXDB_INIT_ADMIN_TOKEN=<ADMIN_TOKEN> \  
influxdb.sif
```
Después es necesario generar **tokens con privilegios mínimos** para Grafana y Telegraf.

Obtener el `bucket ID`:
```
apptainer exec influxdb.sif influx bucket list \  
--org icacc \  
--token "$TOKEN"
```
Crear token de solo lectura para Grafana:
```
apptainer exec influxdb.sif influx auth create \  
--org icacc \  
--read-bucket $BUCKET \  
--description "grafana-read-only"
```
Crear token de escritura para Telegraf:
```

apptainer exec influxdb.sif influx auth create \  
--org icacc \  
--write-bucket $BUCKET \  
--description "telegraf-writer"
```
---

## Grafana

Inicializar Grafana:
```
apptainer run \  
--bind ~/containers/grafana/data:/var/lib/grafana \  
--bind ~/containers/grafana/provisioning:/etc/grafana/provisioning:ro \  
--env GF_SECURITY_ADMIN_USER=admin \  
--env GF_SECURITY_ADMIN_PASSWORD=<PASSWORD> \  
grafana.sif
```
Después colocar el token de lectura de InfluxDB en`grafana.env`, en la variable `INFLUX_TOKEN`.

---

## Telegraf

La configuración principal se define en `telegraf.conf`.

Ejemplo de ejecución:
```
apptainer exec \  
--bind ./telegraf:/etc/telegraf:ro \  
--env INFLUX_URL=http://127.0.0.1:8086 \  
--env INFLUX_TOKEN=<TELEGRAF_TOKEN> \  
--env INFLUX_ORG=icacc \  
--env INFLUX_BUCKET=monitoreo \  
telegraf.sif \  
telegraf \  
--config /etc/telegraf/telegraf.conf \  
--config-directory /etc/telegraf/telegraf.d
```
---

# Visualización en Grafana

Una vez desplegado el sistema se puede acceder a:
```
http://localhost:8086
```
para verificar que InfluxDB esté recibiendo datos.

Grafana se encuentra en:
```
http://localhost:3000
```
En Grafana se pueden crear dashboards usando **queries Flux** como los siguientes.

## Temperatura de PDU
```
from(bucket: "monitoreo")  
|> range(start: v.timeRangeStart, stop: v.timeRangeStop)  
|> filter(fn: (r) => r["_measurement"] == "apc_pdu")  
|> filter(fn: (r) => r["_field"] == "Temperatura")
```
## Uso de CPU
```
from(bucket: "monitoreo")  
|> range(start: v.timeRangeStart, stop: v.timeRangeStop)  
|> filter(fn: (r) => r._measurement == "cpu")  
|> filter(fn: (r) => r.cpu == "cpu-total")  
|> filter(fn: (r) => r._field == "usage_idle")  
|> map(fn: (r) => ({ r with _value: 100.0 - r._value }))
```
## Uso de memoria
```
from(bucket: "monitoreo")  
|> range(start: -1h)  
|> filter(fn: (r) => r._measurement == "mem")  
|> filter(fn: (r) => r._field == "used_percent")  
|> yield(name: "memory_used_percent")
```
## Uso de disco
```
from(bucket: "monitoreo")  
|> range(start: -1h)  
|> filter(fn: (r) => r._measurement == "disk")  
|> filter(fn: (r) => r.path == "/")  
|> filter(fn: (r) => r._field == "used_percent")  
|> yield(name: "disk_used_percent")
```
---

# Problemas encontrados

## Carga de MIB en SNMP

Durante el desarrollo se intentó cargar la MIB oficial de APC para interpretar los OIDs de la PDU. Sin embargo, SNMP generaba errores al intentar adoptar los identificadores.

Ejemplo de error:
```
Cannot adopt OID in NET-SNMP-EXTEND-MIB  
Unknown object identifier
```
Esto se debe principalmente a que muchas **MIB tienen licencias restrictivas** y no se distribuyen en repositorios de software libre como Debian.

Además, la herramienta `snmp-mib-downloader` fue retirada de los repositorios oficiales de **Debian 12**.

---

## Actualización de firmware de la PDU

Para habilitar acceso completo a los sensores fue necesario actualizar el firmware de las PDUs **APC AP8841**.

El firmware se puede descargar desde el sitio de **Schneider Electric**.

La actualización puede realizarse mediante **FTP** cargando los archivos en el siguiente orden:

1. `bootmon`
2. `aos`
3. `rpdu2g`

---
# Soluciones intentadas sin éxito  
  
Durante el desarrollo se probaron varias soluciones para obtener la temperatura del sensor de la PDU mediante SNMP, las cuales no funcionaron por diferentes motivos.  
  
## Uso de MIB oficial de APC  
  
Se intentó cargar la MIB oficial de APC para poder traducir los OIDs a nombres de objeto legibles.  
Pasos realizados:  
1. Copiar la MIB a `/usr/share/snmp/mibs/`  
2. Modificar `/etc/snmp/snmp.conf`  
3. Ejecutar:  
```
snmptranslate -m ALL -IR rPDUIdentModelNumber
```
  
Sin embargo SNMP producía errores como:  
```
Cannot adopt OID in NET-SNMP-EXTEND-MIB  
Unknown object identifier
```
  
Esto impidió que los identificadores fueran cargados correctamente.  
  
## Uso de snmp-mib-downloader  
  
También se intentó instalar:  
```
snmp-mib-downloader
```
  
pero esta herramienta fue retirada de los repositorios oficiales de **Debian 12** debido a restricciones de licencia en muchas MIBs.  
  
Incluso agregando repositorios `non-free` no fue posible obtener las MIB necesarias.  
  
## Uso de Alpine Linux  
  
Se intentó replicar el entorno utilizado en un proyecto anterior utilizando **Alpine Linux** dentro de un contenedor, siguiendo exactamente el mismo procedimiento documentado en dicho proyecto.  
  
El resultado fue el mismo: SNMP continuaba sin poder adoptar correctamente los OIDs definidos en la MIB.  

## Configuración para activar dashboards públicos
## Conclusión  
  
Debido a estos problemas se optó por identificar manualmente los OIDs relevantes mediante `snmpwalk` y verificar los valores devueltos comparándolos con la información mostrada en la interfaz web de la PDU.
# Referencias

- [https://www.influxdata.com](https://www.influxdata.com)
    
- [https://grafana.com](https://grafana.com)
    
- https://www.apptainer.org
    
- [https://www.se.com/mx/es/](https://www.se.com/mx/es/)