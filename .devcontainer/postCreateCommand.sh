#!/bin/bash

function main {
  # need to reload vscode to enable cmake language server

  # enable coredump
  sudo sysctl -w kernel.core_pattern="/coredumps/core-%e-%s-%u-%g-%p-%t"

  mkdir -p $HOME/.config/ccache
  echo "cache_dir = /opt/ccache" >> $HOME/.config/ccache/ccache.conf
  echo "max_size = 20.0G" >> $HOME/.config/ccache/ccache.conf

  echo "unset http_proxy" >> $HOME/.bashrc
  echo "unset https_proxy" >> $HOME/.bashrc
  echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> $HOME/.bashrc

  # ensure claude code config directory has correct ownership
  mkdir -p $HOME/.claude
  sudo chown -R $(id -u):$(id -g) $HOME/.claude

  # replace container settings.json with our project settings.json
  pushd $HOME/.vscode-server/data/Machine
  rm -rf settings.json
  ln -s /opt/transwarp/ducklake/.devcontainer/settings.json settings.json
  popd
}

main $@
