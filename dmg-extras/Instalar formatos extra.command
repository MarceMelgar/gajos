#!/bin/bash
# Instala Homebrew (si falta), ffmpeg y webp, para que Gajos pueda usar
# MP3, OPUS, OGG, WEBM, MKV, AVI y WEBP. Gajos funciona sin esto, pero sin esos formatos.
set -e

echo "Este instalador agrega ffmpeg y webp, para que Gajos use MP3, OPUS, OGG, WEBM, MKV, AVI y WEBP."
echo "Puede pedirte la contraseña de tu Mac: mientras la escribís no se ve nada, es normal."
echo
read -r -p "Apretá Enter para seguir, o cerrá esta ventana para cancelar... "

find_brew() {
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$b" ]; then echo "$b"; return; fi
  done
}

BREW="$(find_brew)"
if [ -z "$BREW" ]; then
  echo "==> Instalando Homebrew (tarda unos minutos)..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  BREW="$(find_brew)"
  if [ -z "$BREW" ]; then
    echo "No se pudo instalar Homebrew."
    read -r -p "Apretá Enter para cerrar."
    exit 1
  fi
  # Para que la Terminal encuentre brew de ahora en más.
  if ! grep -q "brew shellenv" ~/.zprofile 2>/dev/null; then
    echo >> ~/.zprofile
    echo "eval \"\$($BREW shellenv)\"" >> ~/.zprofile
  fi
fi

echo "==> Instalando ffmpeg y webp (si pregunta, respondé y + Enter)..."
"$BREW" install ffmpeg webp

echo
echo "Listo. Gajos ya puede usar todos los formatos (no hace falta reiniciarlo)."
read -r -p "Apretá Enter para cerrar."
