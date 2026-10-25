#!/usr/bin/env bash
# Pruebas de sg-bt-agent. No tocan tu Bluetooth: levantan un D-Bus privado (dbus-launch) con un BlueZ
# falso, y reemplazan notify-send por un script que "responde" lo que diga el archivo modo.
#   bash tests/test-sg-bt-agent.sh        (tarda unos 35 s: un caso espera el tiempo límite de 30 s)
# Requiere: python3-dbus, python3-gobject, dbus-launch (dbus-x11 o dbus-daemon).
# shellcheck disable=SC2016  # los $ entre comillas simples son para los scripts falsos
set -uo pipefail
AQUI="$(cd "$(dirname "$0")" && pwd)"
AGENTE="${SG_BT_AGENTE:-$(dirname "$AQUI")/sg-bt-agent}"   # SG_BT_AGENTE: probar otra versión
T="$(mktemp -d)" || { echo "no se pudo crear la carpeta temporal" >&2; exit 1; }
[ -d "$T" ] || exit 1
cd "$T" || exit 1
pids=()
limpiar() { for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done; [ -n "${DBUS_SESSION_BUS_PID:-}" ] && kill "$DBUS_SESSION_BUS_PID" 2>/dev/null; rm -rf "${T:?}"; }
trap limpiar EXIT
pasaron=0; fallaron=0

# ---------- BlueZ falso: AgentManager1 + un dispositivo con Alias y Trusted ----------
cat > bluez_falso.py <<'EOF'
import dbus, dbus.service, dbus.mainloop.glib
from gi.repository import GLib
dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
bus = dbus.SessionBus(); nombre = dbus.service.BusName("org.bluez.prueba", bus)
class Manager(dbus.service.Object):
    @dbus.service.method("org.bluez.AgentManager1", in_signature="os", sender_keyword="quien")
    def RegisterAgent(self, ruta, capacidad, quien=None):
        print("REGISTRADO", ruta, capacidad, flush=True); open("agente.nombre", "w").write(quien)
    @dbus.service.method("org.bluez.AgentManager1", in_signature="o")
    def RequestDefaultAgent(self, ruta): print("PREDETERMINADO", ruta, flush=True)
class Dispositivo(dbus.service.Object):
    @dbus.service.method("org.freedesktop.DBus.Properties", in_signature="ss", out_signature="v")
    def Get(self, i, p): return {"Alias": "Mouse\x07 de prueba", "Trusted": False}[p]
    @dbus.service.method("org.freedesktop.DBus.Properties", in_signature="ssv")
    def Set(self, i, p, v): print("TRUSTED", bool(v), flush=True)
Manager(bus, "/org/bluez"); Dispositivo(bus, "/org/bluez/hci0/dev_PRUEBA")
GLib.MainLoop().run()
EOF
# ---------- cliente: hace de BlueZ llamando al agente ----------
cat > cliente.py <<'EOF'
import dbus, sys
bus = dbus.SessionBus()
a = dbus.Interface(bus.get_object(sys.argv[1], "/org/serpantinum/btagent"), "org.bluez.Agent1")
dev = dbus.ObjectPath("/org/bluez/hci0/dev_PRUEBA"); m = sys.argv[2]
try:
    if m == "confirmar": a.RequestConfirmation(dev, dbus.UInt32(123456), timeout=60)
    elif m == "autorizar": a.RequestAuthorization(dev, timeout=60)
    elif m == "pin": a.RequestPinCode(dev, timeout=60)
    print("ACEPTADO")
except dbus.DBusException as e: print(e.get_dbus_name())
EOF
# ---------- notify-send falso: responde según el archivo "modo" ----------
cat > notify-falso <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$(dirname "$0")/notificaciones.log"
case "$*" in *--action*) ;; *) exit 0 ;; esac
case "$(cat "$(dirname "$0")/modo")" in
  aceptar) sleep 0.3; echo yes ;; rechazar) sleep 0.3; echo no ;; cerrar) sleep 0.3 ;; esperar) sleep 100 ;;
esac
EOF
chmod +x notify-falso

eval "$(dbus-launch --sh-syntax)" || { echo "falta dbus-launch" >&2; exit 1; }
arrancar_bluez() { python3 -I bluez_falso.py >> bluez.log 2>&1 & pids+=($!); BLUEZ_PID=$!; sleep 1; }
arrancar_bluez
SG_BT_TEST_SESSION_BUS=1 SG_BT_BUS_NAME=org.bluez.prueba SG_BT_NOTIFY="$T/notify-falso" \
    python3 -I "$AGENTE" > agente.log 2>&1 & pids+=($!)
sleep 1.5
AG="$(cat agente.nombre 2>/dev/null)"

caso() { printf '%-58s' "$1"; }
bien() { echo "✅"; pasaron=$((pasaron + 1)); }
mal()  { echo "❌  $*"; fallaron=$((fallaron + 1)); }
pedir() { echo "$1" > modo; python3 -I cliente.py "$AG" "$2" 2>/dev/null | tail -1; }

caso "1. se registra como agente predeterminado (DisplayYesNo)"
    if grep -q "REGISTRADO /org/serpantinum/btagent DisplayYesNo" bluez.log && grep -q PREDETERMINADO bluez.log; then bien; else mal "$(cat bluez.log agente.log)"; fi
caso "2. Aceptar → acepta y marca el dispositivo como de confianza"
    r=$(pedir aceptar confirmar); if [ "$r" = ACEPTADO ] && grep -q "TRUSTED True" bluez.log; then bien; else mal "$r"; fi
caso "3. Rechazar → org.bluez.Error.Rejected"
    r=$(pedir rechazar confirmar); if [ "$r" = org.bluez.Error.Rejected ]; then bien; else mal "$r"; fi
caso "4. cerrar la notificación → rechaza"
    r=$(pedir cerrar autorizar); if [ "$r" = org.bluez.Error.Rejected ]; then bien; else mal "$r"; fi
caso "5. dispositivo que pide escribir un PIN → rechaza con aviso"
    r=$(pedir aceptar pin); if [ "$r" = org.bluez.Error.Rejected ] && grep -q "PIN" notificaciones.log; then bien; else mal "$r"; fi
caso "6. BlueZ cancela a mitad → org.bluez.Error.Canceled"
    echo esperar > modo; (python3 -I cliente.py "$AG" confirmar > cancelado.txt 2>/dev/null &); sleep 1.5
    dbus-send --session --print-reply --dest="$AG" /org/serpantinum/btagent org.bluez.Agent1.Cancel > /dev/null; sleep 1.5
    r=$(tail -1 cancelado.txt); if [ "$r" = org.bluez.Error.Canceled ]; then bien; else mal "$r"; fi
caso "7. el nombre con caracteres de control se limpia"
    if grep -q $'\x07' notificaciones.log; then mal "la notificación tiene caracteres de control"; else bien; fi
caso "8. BlueZ se reinicia → el agente se vuelve a registrar"
    kill "$BLUEZ_PID"; sleep 1; arrancar_bluez; sleep 1
    if [ "$(grep -c REGISTRADO bluez.log)" -ge 2 ]; then bien; else mal "no se volvió a registrar"; fi
AG="$(cat agente.nombre)"
caso "9. sin respuesta en 30 s → rechaza (nunca acepta solo)"
    inicio=$(date +%s); r=$(pedir esperar autorizar); dur=$(( $(date +%s) - inicio ))
    if [ "$r" = org.bluez.Error.Rejected ] && [ "$dur" -ge 29 ] && [ "$dur" -le 40 ]; then bien; else mal "$r en ${dur}s"; fi

echo; echo "Resultado: $pasaron pasaron, $fallaron fallaron"
[ "$fallaron" -eq 0 ]
