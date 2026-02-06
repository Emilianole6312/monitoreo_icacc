# Objetivo 
Crear un sistema de monitoreo de trabajo, temperatura y humedad entre otras metricas para un cluster HPC mediante el uso de las herramientas Influxdb, Grafana, Telegraf y SNMP deslplegadas a traves de contenedores apptainer.

# Desarrollo

## Contenedores
Para este proyecto se utilizaron 3 contenedores distintos para los distintos servicios que componen el sistema de monitoreo, estos contenedores son tomados directamente de dockerhub pero construidos con apptainer.
### INFLUXDB
Primero es necesario crear el contenedor con la imagen de dockerhub:
```
apptainer pull influxdb.sif docker://influxdb:latest
```
Posteriormente es necesario crear un directorio para guardar la información persistente de InfluxDB y otro para las configuraciones, para después hacer una industrialización utilizando variables de entorno:
```
apptainer run \
--bind ./influxdb/data:/var/lib/influxdb2 \
--bind ./influxdb/conf:/etc/influxdb2 \
--env DOCKER_INFLUXDB_INIT_MODE=setup \
--env DOCKER_INFLUXDB_INIT_USERNAME=admin \
--env DOCKER_INFLUXDB_INIT_PASSWORD=admin123 \
--env DOCKER_INFLUXDB_INIT_ORG=icacc \
--env DOCKER_INFLUXDB_INIT_BUCKET=monitoreo \
--env DOCKER_INFLUXDB_INIT_ADMIN_TOKEN=mi-token-super-secreto-xyz123 \
influxdb.sif
```
Y para correr el contenedor una vez inicializado:
```
apptainer run \ 
--bind influxdb-data:/var/lib/influxdb2 \
influxdb.sif
```
#### Creación de  tokens
Para poder conectar InfluxDB con Grafana y con Telegraf es necesario crear token, siguiendo practicas de seguridad adecuadas cada servicio debe tener un token propio con los permisos minimos necesarios para desempenar su funcion.
Para crear un token con acceso a un bucket debemos conocer el id del bucket, para ello es necesario tener el contenedor corriendo con InfluxDb y en otra terminal ejecutar:
```
apptainer exec influxdb.sif influx bucket list \
  --org icacc \
  --token "$TOKEN"
```
Y luego crear el token de solo escritura con:
```
apptainer exec influxdb.sif influx auth create \
  --org icacc \
  --write-bucket $BUCKET \
  --description "telegraf-snmp" \
  --token "$TOKEN"
```
Para crear un token de solo lectura:
```
apptainer exec influxdb.sif influx auth create \
  --org icacc \
  --read-bucket $BUCKET \
  --description "grafana-read-only" \
  --token "$TOKEN"
```
### GRAFANA
Para construir el contenedor de grafana:
```
apptainer build grafana.sif docker://grafana/grafana-oss:latest
```
Para grafana son necesarios dos directorios para montar, en uno se guardan las configuraciones y en el otro la información persistente:
```
apptainer run \
  --bind ./data:/var/lib/grafana \
  --bind ./provisioning:/etc/grafana/provisioning:ro \
  --env GF_SECURITY_ADMIN_USER=admin \
  --env GF_SECURITY_ADMIN_PASSWORD=admin \
  --env INFLUX_TOKEN=$GRAFANA_TOKEN \
  --env GF_SERVER_HTTP_PORT=3000 \
  grafana.sif
```
### TELEGRAF
Para crear el contenedor con Telegraf basta con:
```
apptainer build telegraf.sif docker://telegraf:latest
```
Para usar el contenedor de Telegraf no es necesario montar un directorio para tener persistencia de datos, pero es necesario montar los directorios del sistema para que así este pueda reportar la carga de trabajo del sistema, además es necesario un archivo de configuración de telegraf en el cual se especifica que métricas se van a recolectar, cada cuanto tiempo se reportara y en donde se vaciaran los datos.
```
apptainer run \
  --bind ./telegraf.conf:/etc/telegraf/telegraf.conf:ro \
  --bind /proc:/host/proc:ro \
  --bind /sys:/host/sys:ro \
  --bind /:/hostfs:ro \
  --env HOST_PROC=/host/proc \
  --env HOST_SYS=/host/sys \
  --env HOST_MOUNT_PREFIX=/hostfs \
  --env INFLUX_HOST="http://localhost:8086" \
  --env INFLUX_TOKEN=$TELEGRAF_TOKEN \
  telegraf.sif
```

### Contenedores con instalacion
Para la creación del contenedor se creo un archivo de definición llamado influx.def, se uso un debian 12 obtenido de docker y se llevan a acabo los siguientes pasos en la sección post post:
1. Configuración de no interactive para evitar prompts como la confirmación de instalación de apt
2. Instala los paquetes necesarios
3. Configuración de repositorio oficial de influxdb
4. Instalación de influxdb2

Y en el caso del runscript
1. Inicia el servicio de influxdb y guarda el PID
2. Espera hasta que el servicio este listo
3. Hace el set up de influxdb
4. Empieza a ejecutar un script cada 60 segundos

Para crear un contenedor con el archivo de definición basta con usar:
```
apptainer build ./monitoreo.sif ./monitoreo.def
```
Para ejecutar el contenedor de forma correcta y con persistencia de datos es necesario bindear una carpeta a la ruta `/data` ejemplo: `--bind ./influxdb-data:/data` y la primera ejecución debe incluir la variable `INFLUX_BOOTSTRAP_TOKEN` ej `--env INFLUX_BOOTSTRAP_TOKEN=TOKEN_TEMPORAL`
```
apptainer run   --bind ./influxdb-data:/data   --env INFLUX_BOOTSTRAP_TOKEN=TOKEN_TEMPORAL   monitoreo.sif 
```
## Script 
El script incluye una consulta con SNMP a la PDU para hacer una lectura del sensor de temperatura conectado a la misma.
```
snmpget -v3  -l authPriv \
-u "usuario" \
-a MD5 \
-A "Password" \
-x DES -X "Frase secreta" \
172.18.10.1 \
iso.3.6.1.4.1.318.1.1.26.10.2.2.1.8.3 | awk -F': ' '{print $2}'
```
Incluye el recorte de la información obtenida con awk para obtener únicamente el dato requerido sin  nada mas. Posteriormente se guarda la información en influxdb con:
```
influx write \
  --bucket temperatura \
  --precision s \
  --token "TOKEN_TEMPORAL"\
  "temperatura,host=$(hostname) valor=$TEMP"
```
## Problemas encontrados
### Configuración de MiB con SNMP
Una MiB es una base de datos jerarquica cuya funcion es describir y definir los dispositivos de red gestionables en un equipo de red. Con esta se puede interpretar la información recibida por SNMP traduciendo OIDs (Object Indentifier) en nombres de objeto entendibles. 
Para configurar un MIB con SNMP es necesario:
1. Mover la MiB conseguida a `/usr/share/snmp/mibs/`
2. Modificar el archivo `/etc/snmp/snmp.conf`
	Comentar o elimiar la linea que dice `mibs :`
3. Probar su funcionamiento con 
```
snmptranslate -m ALL -IR rPDUIdentModelNumber
```
Sin embargo, al intentarlo no fue posible cargar la MiB correctamente ya que al hacer `snmptranslate` se recibieron errores del tipo:
```
Cannot adopt OID in NET-SNMP-EXTEND-MIB: nsExtendResult ::= { nsExtendOutput1Entry 4 }
Cannot adopt OID in NET-SNMP-EXTEND-MIB: nsExtendOutNumLines ::= { nsExtendOutput1Entry 3 }
Cannot adopt OID in NET-SNMP-EXTEND-MIB: nsExtendOutputFull ::= { nsExtendOutput1Entry 2 }
Cannot adopt OID in NET-SNMP-EXTEND-MIB: nsExtendOutput1Line ::= { nsExtendOutput1Entry 1 }
Cannot adopt OID in NetBotz50-MIB: netBotzDoorSensorPrefix ::= { netBotzDoorSensorTraps 0 }
Cannot adopt OID in NET-SNMP-EXTEND-MIB: nsExtendOutLine ::= { nsExtendOutput2Entry 2 }
Cannot adopt OID in NET-SNMP-EXTEND-MIB: nsExtendLineIndex ::= { nsExtendOutput2Entry 1 }
Cannot adopt OID in NET-SNMP-AGENT-MIB: nsNotifyStart ::= { netSnmpNotifications 1 }
Cannot adopt OID in NET-SNMP-AGENT-MIB: nsNotifyShutdown ::= { netSnmpNotifications 2 }
Cannot adopt OID in NET-SNMP-AGENT-MIB: nsNotifyRestart ::= { netSnmpNotifications 3 }
Cannot adopt OID in NetBotz50-MIB: doorLockSensorEntry ::= { doorLockSensorTable 1 }
```
y indica que no encontró el objeto identificador con ese nombre a pesar de que al buscar el nombre en la MiB se puede ver el objeto.
```
Unknown object identifier: rPDU2SensorTempHumidity
```
Esto es un problema ya que para hacer la lectura del sensor de temperatura es necesario conocer su OiD o en su defecto que SNMP cargue correctamente la MiB ya que para consultar la temperatura del sensor se debe hacer una consulta del tipo:
```
snmpget -v3  -l authPriv \
... \
$PDU \
{oid a consultar | nombre del objeto a consultar}
```
Sin embargo, al no contar con el oid a consultar no es posible realizar la consulta.
Se descarta el mal funcionamiento de SNMP ya que es posible hacer `snmpwalk` lo cual devuelve todos los OiDs de la PDU junto con su valor, sin embargo, sin un correcto mapeo de los OiDs no es posible interpretar la información. 
#### Motivo
Según lo que investigue el problema se debe a que SNMP es una aplicación de código abierto, sin embargo, los MiB tienen licencias privadas, por lo cual no son distribuidos por canales que solo aceptan software libre como algunos repositorios de Debian, además la herramienta `mib-downloader` fue retirada de los repositorios de debían 12 gracias a los mismos motivos.
#### Soluciones intentadas
##### OiD usada en un proyecto anterior
Ya se había realizado un proyecto similar con netdata y grafana dentro del instituto, el cual dejo un repositorio documentando todo el proceso para la construcción del contenedor, en el mismo se detalla el proceso seguido para poder consultar la temperatura del sensor. 

Dentro de la explicación se siguen los mismos pasos para poder usar la MiB oficial de APC y los programas necesarios incluye `net-snmp` y `net-snmp-tools`, dentro de la segunda herramienta se incluye `snmp-mib-downloader`.

Además en el repositorio se menciona que en el momento en el que se llevo a cabo el proyecto si se logro cargar la MiB correctamente en SNMP, sin embargo,  fue necesario eliminar toda la parte inicial que contiene comentarios que documentan los cambios que se han hecho en las diferentes versiones del archivo ya que esto es lo que genero errores en su caso.

A pesar de seguir los pasos mencionados en el repositorio y eliminar los comentarios SNMP siguió marcando errores al momento de intentar adoptar los OiDs.
#### MiB-downloader y Alpine OS
Ya que el seguir los pasos mencionados en el repositorio no soluciono el problema intente crear el  contenedor con Alpine Os y seguir los pasos exactos del repositorio ya que lo estaba intentando con Debian 12 y algunos pasos debían de cambiar un poco para ser adaptados, sin embargo, esto tampoco dio resultado y me llevo al mismo resultado.

Por otro lado, encontré que aunque `snmp-mib-downloader` no estaba disponible para Debian 12 en los repositorios oficiales de software open source, es posible descargarlo al añadir fuentes non-free en la lista de repositorios a consultar de apt, sin embargo, la lista de repositorios de apt se guarda de forma diferente en un contenedor Debian 12 que en un Debian 12 nativo. Sin embargo, al agregar el software non-free siguio sin ser posible del `snmp-mib-downloader`.
#### Investigación de la OiD en fuentes externas
Debido a que ninguna de las soluciones anteriores funciono decidí buscar otras alternativas ya que SNMP funciona correctamente y devuelve lo solicitado tanto al hacer `snmpwalk` como `snmpget`, aunque de poco sirve ya que aunque pueda recuperar toda la información contenida en la PDU el no poder interpretarla me deja 'ciego'.

Por lo tanto continúe investigando errores similares en el foro de apc y otros para comprobar si las soluciones presentadas me servían para resolver mi problema también. Encontré que el dato se devuelve en formato integer y que este se devuelve sin punto decimal, es decir, si la temperatura es `16.6°` la el valor devuelto será `166`, además se que se cual sea el OiD a consultar este terminara con un 3 ya que mi sensor esta conectado a una PDU conectada a una cadena de PDUs en la cual su identificador es el numero 3 y si existen varios PDUs conectados en cadena el principal arrojara los valores de todos pero con su identificador como ultimo digito del oid. Ejemplo:
Si el OiD del sensor de temperatura es `iso.3.6.1.4.1.318.1.1.26.10.2.2.1.8.1`, entonces el ultimo digito debe ser cambiado al 3, en este caso: `iso.3.6.1.4.1.318.1.1.26.10.2.2.1.8.3`

Bajo estas características comencé a buscar OiDs cuya información coincidiera con estas características, sin embargo, esto no dio resultado, ya que había varios datos que coincidían con las características pero no me daban la certeza de ser la información que yo buscaba.

Entonces intente buscar otras formas de consultar la temperatura y las opciones disponibles resultaron consultarlo a través de la interfaz web y por ssh, sin embargo, para poder consultarlo por SSH fue necesario actualizar el firmware de las PDUs ya que antes de ello no reconocia la presencia del sensor.
### Actualización de firmware de la PDU y Conexión en cadena de las PDU
Para actualizar el firmware de la PDU el primer paso es verificar la versión actual del fimware con la pantalla LCD de la PDU en la sección de firmware.

Posteriormente, es necesario ir al sitio oficial de [Schneider ](https://www.se.com/mx/es/search/?q=AP8841&submit+search+query=Search) y buscar `AP8841` acceder a la sección software y buscar la versión mas reciente del firmware de la Network Managing Card, hacer clic en el y buscar el archivo descargable con extensión `.exe`, posteriormente es necesario descomprimirlo, en el caso de windows basta con ejecutarlo para que este descomprima el archivo y abra un asistente de actualización de firmware, sin embargo, en este caso ocuparemos un sistema con debian para actualizarlo así que solo es necesario descomprimirlo para obtener los archivos:
- `apc_hw05_rpdu2g_XXX.bin`
- `apc_hw05_bootmon_XXX.bin`
- `apc_hw05_aos_XXX.bin`
Una vez que tenemos estos archivos en el host conectado a la PDU se puede realizar la actualización por FTP, cabe mencionar que no es el único método, también es posible a través de la interfaz web y de el puerto USB de la PDU, pero FTP fue el método mas sencillo a mi parecer.
Para actualizar el firmware de la PDU por FTP el primer paso es necesario contar con los archivos de actualización, la IP de la PDU, FTP activado en la PDU y un cliente FTP.
1. Iniciar conexión FTP
```bash
ftp $PDU_IP
```
2. Ingresar credenciales (usuario y contraseña `apc` por defecto). 
```ftp
User: apc
Password: apc
```
3. Configurar modo binario.
```ftp
bin
```
4. Subir el archivo `apc_hw05_bootmon_XXX.bin`.  (IMPORTANTE: Es crucial subir como primero el archivo bootmon)
```
put ruta/al\archivo/apc_hw05_bootmon_XXX.bin
```
5. Esperar a que el archivo se suba y se aplique la actualización, esto cerrara la conexión FTP y tardara un poco en volver a iniciar.
6. Reiniciar conexión FTP (pasos 1-4).
7. Subir archivo `apc_hw05_aos_xxx.bin`
```
put ruta/al/archivo/apc_hw05_aos_XXX.bin
```
8. Esperar a que el archivo se suba y se aplique la actualización, esto cerrara la conexión FTP y tardara un poco en volver a iniciar.
9. Volver a conectar y subir el archivo ``
```
put ruta/al/archivo/apc_hw05_rpdu2g_XXX.bin
```
10. Verificar la versión del firmware con la pantalla LCD o con una conexión por SSH con el comando `about`.
Después de la actualización del firmware podemos conectar las PDU en cadena como indica la documentación del producto conectando con un cable ethernet cat 5e el puerto `out` de la primera PDU a el puerto `in` de la segunda PDU y en caso de requerir conectar mas PDU se sigue la misma lógica hasta un máximo de 4 PDUs.
Es importante que todas las PDU cuenten con la misma versión de firmware, en caso contrario las PDUs no reconocerán la conexión.
Para verificar que las PDU estén correctamente encadenadas es necesario revisar el panel LCD de las mismas que tendrán un numero, el cual es el identificador de la PDU.
# Referencias
- https://gist.github.com/MercadoMR/9be6f6fa60eda125276c81d703c47768
- https://www.se.com/mx/es/
