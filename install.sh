#!/usr/bin/env bash

# =============================================================================
# Dockyard installer
# =============================================================================

set -euo pipefail

readonly INSTALL_DIR="${HOME}/.local/bin"
readonly SCRIPT_NAME="dockyard"
readonly REPO_URL="https://raw.githubusercontent.com/thibautdeg/dockyard/main/dockyard.sh"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "\n${BOLD}${CYAN}⚓  Installing Dockyard...${NC}\n"

# Create install directory
mkdir -p "$INSTALL_DIR"

# Download script
if curl -fsSL "$REPO_URL" -o "${INSTALL_DIR}/${SCRIPT_NAME}"; then
    chmod +x "${INSTALL_DIR}/${SCRIPT_NAME}"
    echo -e "${GREEN}✔${NC}  Installed to ${INSTALL_DIR}/${SCRIPT_NAME}"
else
    # Fallback: if installing from local clone
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "${SCRIPT_DIR}/dockyard.sh" ]]; then
        cp "${SCRIPT_DIR}/dockyard.sh" "${INSTALL_DIR}/${SCRIPT_NAME}"
        chmod +x "${INSTALL_DIR}/${SCRIPT_NAME}"
        echo -e "${GREEN}✔${NC}  Installed from local source to ${INSTALL_DIR}/${SCRIPT_NAME}"
    else
        echo "Error: Could not download or find dockyard.sh"
        exit 1
    fi
fi

# Add to PATH if not already there
SHELL_CONFIG=""
if [[ -f "${HOME}/.zshrc" ]]; then
    SHELL_CONFIG="${HOME}/.zshrc"
elif [[ -f "${HOME}/.bashrc" ]]; then
    SHELL_CONFIG="${HOME}/.bashrc"
elif [[ -f "${HOME}/.bash_profile" ]]; then
    SHELL_CONFIG="${HOME}/.bash_profile"
fi

PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'

if [[ -n "$SHELL_CONFIG" ]] && ! grep -qF "$PATH_LINE" "$SHELL_CONFIG"; then
    echo "" >> "$SHELL_CONFIG"
    echo "# Dockyard" >> "$SHELL_CONFIG"
    echo "$PATH_LINE" >> "$SHELL_CONFIG"
    echo -e "${GREEN}✔${NC}  Added ${INSTALL_DIR} to PATH in ${SHELL_CONFIG}"
fi

echo ""
echo -e "${BOLD}${GREEN}✅ Dockyard installed!${NC}"
echo ""
echo -e "  Restart your terminal or run: ${CYAN}source ${SHELL_CONFIG:-~/.zshrc}${NC}"
echo -e "  Then navigate to a project and run: ${CYAN}dockyard init${NC}"
echo ""
