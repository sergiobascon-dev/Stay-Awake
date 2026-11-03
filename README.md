# Stay Awake

Aplicación nativa de barra de menús para macOS que mantiene el Mac activo durante
sesiones temporizadas o permanentes. Incluye ahorro de energía, pausa selectiva
de aplicaciones, restauración de ajustes y conexión opcional al hotspot del iPhone.

## Cambios propios de seguridad

Partí de Insomnia para añadir controles de seguridad y recuperación que consideraba
necesarios para mi uso. Esta adaptación incorpora:

- Un servicio privilegiado XPC con operaciones limitadas y autenticación de firmas,
  en lugar de reglas generales de sudoers. La vía local exige la compilación exacta
  aprobada y una aplicación protegida por el administrador.
- Concesiones de energía con caducidad y supervisión independiente de la aplicación,
  para intentar restaurar los ajustes si esta deja de responder, además de límites
  de batería y temperatura que no pueden desactivarse desde la interfaz.
- Un diario de energía protegido, escrituras persistentes y verificación de los
  ajustes después de restaurarlos, reforzando la recuperación del proyecto original.
- Actualizaciones y retirada con recuperación previa: se bloquea el reemplazo si
  sigue pendiente restaurar el estado del servicio.

Estos cambios no requieren desactivar Gatekeeper o SIP.

**Estado experimental:** se ha comprobado una sesión breve con tapa cerrada en un
Mac. Siguen pendientes pruebas completas de batería, hotspot y recuperación ante
fallos. No está listo para uso desatendido.

## Desarrollo

Apple Silicon, macOS 26 o posterior y Swift 6.2 o posterior.

```sh
bash scripts/test-local.sh
bash scripts/build-local.sh
```

[Instalación desde código](LOCAL-SOURCE-INSTALL.md) · [Validación](VALIDATION.md)

## Créditos y licencia

Stay Awake está basado en [Insomnia](https://github.com/krishhgg/Insomnia), creado
por [Krish Garg](https://github.com/krishhgg). Gracias a su autor por publicar el
proyecto original como código abierto. Este fork conserva su copyright y la
[licencia MIT](LICENSE). No es una versión oficial de Insomnia.
