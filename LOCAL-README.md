# Stay Awake — desarrollo experimental

Este es un fork local de Insomnia, no una versión oficial ni una aplicación
certificada como segura. Conserva el copyright y la licencia MIT del autor.
Base: `krishhgg/Insomnia`, commit `b8e7e20d617f008179583918599669fc1c13a731`.

**No está listo para dejar un Mac trabajando sin supervisión.** La copia de
código y la compilación de desarrollo no instalan servicios. Las sesiones con
privilegios están bloqueadas en compilaciones ad hoc. La ruta de distribución
exige Developer ID. Hay una vía separada [desde código local](LOCAL-SOURCE-INSTALL.md)
con Apple Development, paquete protegido y autenticación de la compilación exacta;
su instalación real todavía requiere validación supervisada.
No se deben ejecutar las instrucciones de instalación del README original.
Los instaladores heredados están deshabilitados para comandos reales.

## Qué se conserva

- Interfaz de barra de menús basada en la original: ojo cerrado/abierto,
  campos de días/horas/minutos, cuenta atrás y control de finalizar.
- Inicio rápido desde el menú: 30 minutos, 1/2/4/8 horas o duración personalizada.
- Botón ∞ junto a los campos y opción “Permanente · ∞” en el menú.
  Permanente significa hasta finalizar manualmente o actuar una protección,
  sin desactivar la recuperación. Cada permiso de energía dura 60 segundos
  y se renueva mientras responde la aplicación; no se guarda un permiso infinito.
  No se inicia automáticamente una sesión permanente al arrancar el Mac.
- Prevención de reposo con tapa cerrada mediante el servicio de energía firmado.
- Bajo consumo por tapa cerrada, batería y estado térmico.
- Pausa y reanudación de procesos seleccionados, con identificación de proceso,
  hora de creación y arranque del sistema; no se cierran las aplicaciones.
- Protección de agentes, editores y dependencias; Codex y Figma protegidos por
  defecto. La lista puede adaptarse a cada flujo de trabajo.
- Brillo de pantalla/teclado y audio con diario de restauración por dispositivo.
- Regla opcional de Docker inactivo, reconexión al hotspot mediante CoreWLAN y
  credencial en Llavero, automatización explícita de tmux y relanzamiento
  confirmado de navegadores compatibles.
- Avisos de recuperación pendiente, diarios, ajustes y registros locales.

Conservar código no equivale a haber verificado cada integración en hardware.
El hotspot requiere un iPhone disponible, configuración y permisos; no se ha
cambiado la red para probarlo. Pausar aplicaciones requiere probar sus servicios
auxiliares. Brillo/teclado dependen de interfaces privadas y comprobaciones de
compatibilidad. Los límites térmicos emplean estados de macOS, no grados Celsius.

## Cambios de seguridad implementados

1. **Sin sudoers en la ruta de ejecución local.** `SessionManager.live` utiliza
   `BrokerSleepGuard`. Los comandos heredados con sudo quedan para pruebas de
   fixtures; no son una alternativa si el servicio firmado falla.
2. **Servicio XPC de vocabulario cerrado.** El daemon acepta comenzar, renovar,
   liberar, consultar y solicitar bajo consumo; no admite rutas ni comandos.
   El sistema comprueba los mensajes contra identidad de aplicación y Team ID.
   El cliente también exige la identidad del servicio.
3. **Diario del servicio separado y propiedad de root.** Escritura antes del
   efecto, temporal exclusivo, sincronización, renombrado y confirmación de
   lectura al restaurar. Rechaza enlaces, hardlinks y permisos o ACL adicionales.
4. **Plazo y supervisión independientes.** Una comprobación cada cinco segundos
   restaura al caducar, al faltar renovaciones durante 90 segundos, con batería
   <=10%, calor crítico o batería ilegible de forma persistente. Al reiniciar el
   daemon se recupera el diario antes de aceptar sesiones. Una renovación tardía
   no puede crear una nueva sesión. Calor serio o batería <=40% solicitan ahorro.
5. **Recuperación en la sesión del usuario.** Un agente de usuario puede ejecutar
   el propio binario en modo de recuperación, incluyendo los ajustes de audio,
   sin ejecutar CoreAudio como root. La decisión se toma bajo el bloqueo común
   con inicio/finalización. Los dispositivos desconectados permanecen pendientes.
6. **Separación de la aplicación original.** ID `local.insomnialocal.app`, agente
   `local.insomnialocal.recovery`, datos en `~/Library/Application Support/InsomniaLocal`
   y registros en `~/Library/Logs/InsomniaLocal`. El servicio de contraseña del
   Llavero también está separado: `insomnialocal-hotspot`. Se bloquea la consulta
   de actualizaciones oficiales desde esta aplicación para no confundir versiones.
7. **Restauración explícita.** El menú incluye “End session and restore now”
   mientras existe una sesión o diario pendiente.

El servicio root no reanuda procesos ni recibe los archivos del usuario. Solo
controla dos ajustes de energía y su propio diario. No existe garantía de
recuperación ante fallos del sistema, almacenamiento ilegible o comandos del
sistema que no terminan. Nunca usar dentro de una mochila cerrada.

## Compilar sin instalar

Desde esta carpeta:

```sh
./scripts/build-local.sh
```

Crea `build/StayAwake-development.zip`, que contiene la aplicación con firma ad hoc de desarrollo. No registra tareas,
no usa sudo, no cambia ajustes de energía y no desactiva Gatekeeper. La firma
estructural de desarrollo no acredita un desarrollador ni es notarización.
Si ya hay un ZIP, el script se detiene en vez de reemplazarlo. El empaquetado
se hace fuera de Documents y se verifica otra vez tras extraer el ZIP, porque
iCloud puede añadir FinderInfo a carpetas .app y hacer fallar codesign. No se
eliminan atributos de archivos ajenos ni se desactivan protecciones.

Pruebas breves, invocadas explícitamente:

```sh
preview_dir="$(mktemp -d /private/tmp/insomnia-local-preview.XXXXXX)"
/usr/bin/ditto -x -k build/StayAwake-development.zip "$preview_dir"
"$preview_dir/Stay Awake.app/Contents/MacOS/Insomnia" --local-doctor
"$preview_dir/Stay Awake.app/Contents/MacOS/Insomnia" --local-self-test
```

`doctor` solo consulta. `self-test` crea un hijo desechable, confirma su pausa y
reanudación con el kernel, y crea/libera una petición temporal de mantener despierto
el sistema durante dos segundos. No modifica preferencias, red ni aplicaciones
ajenas. Compara energía antes y después y devuelve un JSON con los resultados.
Esto prueba piezas reales; no valida una sesión completa con tapa cerrada.

## Antes de cualquier instalación con privilegios

Faltan validaciones que no se pueden sustituir con dobles de prueba:

- Firma Apple Development y comprobaciones de la vía local protegida, o bien
  Developer ID y notarización para distribución. La identidad se pasa
  con `INSOMNIA_SIGNING_IDENTITY`; no introducir certificados ni claves en el chat.
- Revisar `SMAppService`, autorización y rechazo de clientes sin firma o de otro
  equipo en un Mac de pruebas. No se ha registrado el daemon en este Mac.
- Probar diario propiedad de root, reinicio del servicio y recuperación real de
  energía, sin alterar la sesión de trabajo del usuario.
- Probar apertura/cierre de tapa, caída de la app, retorno de audio/brillo y
  hotspot con supervisión y restauración confirmada.
- Continuar la revisión del daemon y del código heredado antes de distribuir
  versiones destinadas a uso desatendido.
- Validar el instalador y desinstalador locales con una firma real y recuperación supervisada.

Hay dos scripts locales de instalación/desinstalación. Sin argumentos muestran
solo el plan y no modifican nada:

```sh
./scripts/install-local.sh --plan
./scripts/uninstall-local.sh --plan
```

La aplicación de esos planes (`--apply`) exige una compilación firmada y el Team ID
esperado en `INSOMNIA_EXPECTED_TEAM_ID`. El instalador comprueba firma contra ese
equipo y aceptación de Gatekeeper antes de ejecutar/copiar la aplicación; no
reemplaza una instalación existente. El desinstalador pide cerrar únicamente esta
aplicación, restaura energía y el diario del usuario, retira los servicios y solo
entonces elimina sus archivos de ejecución y el bundle. Conserva ajustes, registros,
el archivo de bloqueo y credenciales de hotspot. Si queda audio desconectado u otra
recuperación pendiente se detiene. No se ha ejecutado `--apply` ni se considera esta
ruta validada hasta probarla con una firma real.

La compilación incluye el plist del servicio para SMAppService. Los comandos
`--local-register-power` y `--local-unregister-power` son herramientas de
integración para una futura prueba supervisada; **no se han ejecutado**.
`--local-unregister-power` intenta recuperar energía primero y se niega a
continuar si falla. Todavía no elimina los archivos ni el agente del usuario:
no debe anunciarse como desinstalación completa.

## Validación

Consultar `VALIDATION.md` para resultados, exclusiones y trabajo pendiente.
Las pruebas heredadas de scripts no describen el nuevo instalador ni prueban el
servicio XPC real. No instalar versiones nightly del proyecto original por
confusión con esta copia local.

## Micrófono con tapa cerrada

Nota correspondiente a la interfaz: on Mac laptops with Apple silicon or a T2
chip, closing the lid disconnects the built-in microphone in hardware. Recording
a meeting with the lid closed needs AirPods or an external mic.

## Publicación del código

El README público es deliberadamente breve. Los workflows originales se
conservan como fixtures en `docs/upstream-github/`, fuera de `.github/`, para
que no se ejecuten al subir el repositorio. Los tests estáticos leen ese archivo
histórico, no atribuyen sus versiones o garantías a Stay Awake. El código se
publica en [sergiobascon-dev/Stay-Awake](https://github.com/sergiobascon-dev/Stay-Awake)
como proyecto experimental. Siguen pendientes las comprobaciones reales de
funcionamiento que se detallan en VALIDATION.md.
