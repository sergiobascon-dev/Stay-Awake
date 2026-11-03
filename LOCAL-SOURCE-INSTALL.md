# Instalación local de Stay Awake

Esta vía está destinada al código compilado localmente. Requiere una identidad
Apple Development válida en el Llavero del Mac que compila la aplicación. No es un instalador notarizado para distribuir a terceros.
No se exporta la clave privada ni se cambia Gatekeeper, SIP o sudoers.

## Qué instala

El paquete `build/StayAwake-local-source.pkg` copia únicamente la aplicación a:

`/Library/Application Support/InsomniaSafeLocal/Stay Awake.app`

Es una ubicación protegida por el administrador. El componente no tiene scripts preinstall/postinstall ni registra servicios
ni modifica ajustes de energía. El asistente incluye una comprobación JavaScript
de solo lectura, sin permiso para ejecutar comandos externos, que impide
sobrescribir instalaciones o recuperaciones anteriores. No modifica
los permisos de /Applications ni incluye esos directorios en su carga útil.
La primera instalación debe estar vacía: no se admiten actualizaciones encima
de una sesión o instalación anterior. Retirar primero la versión anterior.

## Pasos supervisados

1. Abrir el paquete creado localmente y revisar el destino en Instalador.
2. Completar la instalación autorizándola con el diálogo de macOS.
3. Abrir Stay Awake.app en la ubicación anterior. Aparece el ojo en la barra
   de menús y se abren los ajustes si falta el servicio de energía.
4. En «Servicio de energía», pulsar «Configurar servicio». Autorizarlo en
   Ajustes del Sistema cuando macOS lo solicite. No empieza ninguna sesión.
5. Volver a la aplicación y pulsar «Comprobar». Debe indicar «Disponible» y que
   la identidad del servicio está verificada. Si aparece un error, detenerse.
6. Hacer primero una sesión breve con la tapa abierta. Después comprobar
   restauración, tapa cerrada y hotspot por separado, con supervisión.

La instalación y el registro reales todavía necesitan validación. No usar de
forma desatendida ni transportar el Mac dentro de una bolsa durante las pruebas.

## Controles de esta vía

El modo local se selecciona al compilar, nunca desde una preferencia o variable
de entorno del servicio. Exige Apple Development, Hardened Runtime y ausencia
de entitlements. Ambos extremos XPC fijan el cdhash de la compilación exacta:
una copia modificada y vuelta a firmar con la misma clave queda rechazada.
Antes de autorizar privilegios se revisan propietario root, permisos, ACL y
enlaces de la aplicación y sus antecesores. La vía de distribución conserva
su exigencia Developer ID Application; no acepta firmas de desarrollo.

Si falla la autenticación al arrancar el daemon, no se publica el endpoint XPC.
El supervisor continúa en modo de recuperación para intentar restaurar cualquier
concesión pendiente. Esta conducta aún requiere una prueba real como root.

## Retirada

`bash scripts/remove-local-source.sh --plan` explica la retirada sin cambios.
`--apply` pide a la aplicación restaurar y retirar los servicios antes de solicitar
autorización del administrador. El paso de administrador comprueba por separado
que no quede daemon cargado ni diario de energía. Si queda algo, se niega a
borrar la aplicación. Conserva preferencias, registros, credenciales del hotspot
y el bloqueo de recuperación. Esta retirada real también está pendiente de prueba.

## Reproducir la compilación

```bash
INSOMNIA_BUILD_CHANNEL=local-development \
INSOMNIA_SIGNING_IDENTITY='<identidad Apple Development de tu Llavero>' \
bash scripts/build-local.sh
bash scripts/package-local-source.sh
INSOMNIA_SIGNING_IDENTITY='<misma identidad>' bash scripts/test-local-source.sh
```

Los scripts se niegan a sobrescribir archivos de entrega existentes. El uso de la
clave de firma puede solicitar permiso de Llavero. No se necesitan contraseñas,
certificados ni claves privadas en el chat o el repositorio.

## Actualización con recuperación previa

Para 0.3.1 existe `build/StayAwake-local-update.pkg`, generado con
`bash scripts/package-local-source.sh --update`. Antes de abrirlo hay que ejecutar
la preparación con el binario instalado (`--local-prepare-uninstall`): cierra la
app, restaura y retira servicios, conservando la aplicación y datos. El paquete
rechaza un almacén root pendiente y exige que todas las copias estén cerradas.
El paquete inicial conserva su negativa a sobrescribir una instalación existente.
Después de actualizar hay que abrir Stay Awake y configurar/verificar el servicio.
La retirada o actualización real aún necesita completar su validación supervisada.
