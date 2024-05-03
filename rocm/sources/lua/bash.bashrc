if ! shopt -q login_shell; then
  if [ -d /etc/profile.d ]; then
    for i in /etc/profile.d/*.sh; do
      if [ -r \$i ]; then
        . \$i
      fi
    done
  fi
fi

