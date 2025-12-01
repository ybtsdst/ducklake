#!/bin/bash

function main {
  # need to reload vscode to enable cmake language server

  mkdir -p $HOME/.config/ccache
  echo "cache_dir = /opt/ccache" >> $HOME/.config/ccache/ccache.conf
  echo "max_size = 20.0G" >> $HOME/.config/ccache/ccache.conf

  # replace container settings.json with our project settings.json
  pushd $HOME/.vscode-server/data/Machine
  rm -rf settings.json
  ln -s /opt/transwarp/ducklake/.devcontainer/settings.json settings.json
  popd
}

main $@
