# Estado de validación

Stay Awake es un fork experimental para Apple Silicon y macOS 26 o posterior.
Las pruebas se ejecutaron en un Mac con macOS 27.2 y Swift 6.4.2. No se ha
comprobado compatibilidad con otras máquinas ni versiones de macOS.

## Pruebas automatizadas

Ejecutar `bash scripts/test-local.sh`. Usa directorios temporales y dobles para
las mutaciones de energía, audio y procesos de otras aplicaciones. Las pruebas
del almacén también comprueban permisos, ACL, enlaces, FIFOs y persistencia real.
No instalan servicios ni cambian los ajustes de energía del usuario.

Las suites heredadas `RecoveryScriptTests` y `PackagingTests` se excluyen porque
no validan la ruta nueva de instalación/XPC. Las pruebas tmux se omiten cuando
esa dependencia no está instalada. Los resultados de las ejecuciones se solapan;
no deben sumarse como casos independientes.

La corrección de final de sesión pasó 130 pruebas focalizadas. La revisión para
publicación ejecutó 1.112 casos, con 13 omitidos por falta de tmux. Detectó dos
aserciones que aún esperaban el nombre Insomnia en un mensaje: se actualizaron
a Stay Awake y la suite afectada volvió a pasar sus 8 casos sin fallos. Las
restantes comprobaciones pasaron en la ejecución general. El historial local y
los registros con datos de usuarios no se publican.

## Comprobaciones reales realizadas

- Firma Apple Development, Hardened Runtime y comprobación del paquete instalado.
- Autenticación XPC entre aplicación y servicio; rechazo de identidades distintas.
- Rechazo de recursos alterados y de una copia modificada y firmada con la misma clave.
- Proceso hijo desechable pausado/reanudado y petición temporal IOKit creada/liberada.
- Instalador expandido: firma del payload, propietario root, permisos y ausencia
  de scripts preinstall/postinstall. El preflight no ejecuta comandos externos.
- Instalación y registro supervisados del servicio en un Mac.
- Sesión temporizada breve con corriente y tapa cerrada: hubo actividad durante
  el cierre, sin entradas Sleep/Wake; al terminar se restableció el reposo y se
  restauraron los procesos, el sonido y el brillo registrados.
- Preparación de actualización con restauración previa y retirada del servicio:
  el instalador bloqueó antes de preparar y permitió continuar después.

Esto demuestra esas operaciones concretas, no garantiza la continuidad de cualquier
trabajo de una aplicación ni certifica la seguridad del proyecto.

## Correcciones incluidas en el código

- Arranque GUI síncrono para que las tareas MainActor, botones y cierre funcionen
  dentro del bucle AppKit. El binario incluye `--local-gui-self-test` para detectarlo.
- Modelo observable del servicio en la raíz de ajustes, con errores visibles y
  disponibilidad condicionada a un intercambio XPC autenticado.
- Fin de sesión que cancela la renovación aunque otro supervisor ya haya limpiado
  el diario. Una expiración esperada no genera un falso aviso de recuperación;
  una pérdida anticipada o de una sesión permanente sigue notificándose.

## Pendiente

- Prueba real del cambio Wi-Fi → hotspot del iPhone, pérdida de cobertura y retorno.
- Continuidad medida de trabajos reales durante sesiones largas con tapa cerrada.
- Funcionamiento con batería, límites térmicos y de batería en hardware real.
- Recuperación completa tras caída, reinicio, desconexión de dispositivos y errores
  reales de persistencia o de pmset; retirada completa del software.
- Notarización, distribución de binarios y revisión externa de seguridad.

No se considera listo para sesiones desatendidas. La publicación del código
fuente no constituye una certificación de funcionamiento o seguridad.
