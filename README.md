# Stay Awake

Aplicación nativa de barra de menús para macOS que mantiene el Mac activo durante
sesiones temporizadas o permanentes. Incluye ahorro de energía, pausa selectiva
de aplicaciones, restauración de ajustes y conexión opcional al hotspot del iPhone.

Utiliza un servicio de energía con operaciones limitadas, diarios de recuperación
y protecciones de batería y temperatura. No añade reglas generales de sudoers ni
desactiva Gatekeeper o SIP.

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
