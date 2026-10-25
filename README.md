# sg-bt-agent

Agente de emparejamiento Bluetooth para **Serpantinum** (Hyprland + Quickshell).

El panel de Serpantinum empareja con `device.pair()`, pero no registra un **agente** de BlueZ.
Sin agente, BlueZ rechaza el emparejamiento (`No agent available for request type 2`).
Este agente pregunta con una **notificación de Serpantinum**:

> **¿Emparejar Microsoft Bluetooth Mouse?** — `Rechazar` · `Aceptar`

## Seguridad
- **Nunca acepta solo.** Sin respuesta en 30 s, o si cierras la notificación → rechaza.
- `Rechazar` es la **primera** acción: en Serpantinum, un clic en el cuerpo de la notificación ejecuta
  la primera acción, así que un clic accidental **rechaza**.
- Capacidad `DisplayYesNo`: puede mostrar un código y preguntar sí/no. No acepta PIN escritos:
  esos casos se rechazan con un aviso (usar `bluetoothctl`).
- Nombre del dispositivo saneado (solo caracteres imprimibles, máximo 64).
- Al aceptar marca el dispositivo como de confianza (`Trusted`) para que se reconecte solo.
- Solo corre en la sesión de Hyprland (`WantedBy=hyprland-session.target`); GNOME usa el suyo.

## Pruebas
Con un BlueZ falso en un D-Bus privado y un `notify-send` simulado (`SG_BT_TEST_SESSION_BUS=1`,
`SG_BT_BUS_NAME`, `SG_BT_NOTIFY`): aceptar, rechazar, cerrar, sin respuesta (30 s), PIN, `Cancel`
y BlueZ reiniciado (vuelve a registrarse).

## Instalación
```bash
install -Dm755 sg-bt-agent ~/.local/bin/sg-bt-agent
install -Dm644 sg-bt-agent.service ~/.config/systemd/user/sg-bt-agent.service
systemctl --user daemon-reload && systemctl --user enable --now sg-bt-agent.service
```

## Licencia
Copyright (C) 2026 Ekzzzzzz.

Este programa es software libre: puedes redistribuirlo y modificarlo bajo los términos de la
**GNU Affero General Public License** publicada por la Free Software Foundation, versión 3 o
(a tu elección) cualquier versión posterior. Ver [`LICENSE`](LICENSE).

*License: AGPL-3.0-or-later. A BlueZ pairing agent that asks through desktop notifications (made for Serpantinum).*
