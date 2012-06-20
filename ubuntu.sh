#!/usr/bin/env bash

set -e

[ -z "$SUDO" ] && SUDO='sudo'

# {{{ Utils

# Return the value of the first argument or exit with an error message if empty.
script-argument-create() {
  [ -z "$1" ] && {
    echo "You must specify $2 to '${BASH_SOURCE[0]}'." 1>&2
    exit 1
  }
  echo "$1"
}

# }}}

# {{{ Nameservers

# Drop all local 10.0.x.x nameservers in 'resolv.conf'.
nameservers-local-purge() {
  $SUDO sed -e 's#nameserver\s*10\.0\..*$##g' -i '/etc/resolv.conf'
}

# Set up an IP as a DNS name server if not already present in 'resolv.conf'.
nameservers-append() {
  grep "$1" '/etc/resolv.conf' > /dev/null || \
    ( echo "nameserver $1" | $SUDO tee -a '/etc/resolv.conf' > /dev/null )
}

# }}}

# {{{ Aptitude

# Set up a specific two-letter country code as the preferred `aptitude` mirror.
apt-mirror-pick() {
  $SUDO sed -i \
    -e "s#\w\+\.archive\.ubuntu\.com#$1.archive.ubuntu.com#g" \
    -e "s#security\.ubuntu\.com#$1.archive.ubuntu.com#g" \
    '/etc/apt/sources.list'
}

# Add a Launchpad PPA as a software source.
apt-packages-ppa() {
  local ppa_name
  ppa_name=$( echo "$1" | sed -e 's#[^[:alnum:]]\+#-#g' )
  ( cat <<-EOD
deb     http://ppa.launchpad.net/$1/ubuntu lucid main
deb-src http://ppa.launchpad.net/$1/ubuntu lucid main
EOD
  ) | $SUDO tee "/etc/apt/sources.list.d/$ppa_name.list" > /dev/null
  $SUDO apt-key adv --keyserver "${3:-keyserver.ubuntu.com}" --recv-keys "$2"
}

# Update `aptitude` packages without any prompts.
apt-packages-update() {
  $SUDO apt-get -q update
}

# Perform an unattended installation of package(s).
apt-packages-install() {
  $SUDO                                    \
    DEBIAN_FRONTEND=noninteractive         \
    apt-get                                \
      -o Dpkg::Options::='--force-confdef' \
      -o Dpkg::Options::='--force-confold' \
      -f -y -q                             \
    install                                \
      $*
}

# }}}

# {{{ Default Commands

# Update the Ruby binary link to point to a specific version.
# TODO: ($bin_path = '/usr/bin/', $man_path = '/usr/share/man/man1/', $priority = 500)
alternatives-ruby-install() {
  local bin_path
  local man_path
  bin_path="${2:-/usr/bin/}"
  man_path="${3:-/usr/share/man/man1/}"
  $SUDO update-alternatives                                                         \
    --install "${bin_path}ruby"      ruby      "${bin_path}ruby$1"      "${4:-500}" \
    --slave   "${man_path}ruby.1.gz" ruby.1.gz "${man_path}ruby$1.1.gz"             \
    --slave   "${bin_path}ri"        ri        "${bin_path}ri$1"                    \
    --slave   "${bin_path}irb"       irb       "${bin_path}irb$1"                   \
    --slave   "${bin_path}rdoc"      rdoc      "${bin_path}rdoc$1"
  $SUDO update-alternatives --verbose                                               \
    --set                            ruby      "${bin_path}ruby$1"
}

# Create symbolic links to RubyGems binaries.
alternatives-ruby-gems() {
  local ruby_binary
  local ruby_version
  local binary_path
  ruby_binary=$( $SUDO update-alternatives --query 'ruby' | grep 'Value:' | cut -d' ' -f2- )
  ruby_version="${ruby_binary#*ruby}"
  if grep -v '^[0-9.]*$' <<< "$ruby_version"; then
    echo "Could not determine version of RubyGems."
  fi
  for binary_name in "$@"; do
    binary_path="/var/lib/gems/$ruby_version/bin/$binary_name"
    $SUDO update-alternatives --install "$( dirname "$ruby_binary" )/$binary_name" "$binary_name" "$binary_path" 500
    $SUDO update-alternatives --verbose --set                                      "$binary_name" "$binary_path"
  done
}

# }}}

# {{{ Apache

# Enable a list of Apache modules. This requires a server restart.
apache-modules-enable() {
  $SUDO a2enmod $*
}

# Disable a list of Apache modules. This requires a server restart.
apache-modules-disable() {
  $SUDO a2dismod $*
}

# Enable a list of Apache sites. This requires a server restart.
apache-sites-enable() {
  $SUDO a2ensite $*
}

# Disable a list of Apache sites. This requires a server restart.
apache-sites-disable() {
  $SUDO a2dissite $*
}

# Create a new Apache site and set up Fast-CGI components.
apache-sites-create() {
  local apache_site_name
  local apache_site_path
  local apache_site_user
  local apache_site_group
  local apache_site_config
  local cgi_action
  local cgi_apache_path
  local cgi_system_path
  local code_block
  apache_site_name="$1"
  apache_site_path="${2:-/$apache_site_name}"
  apache_site_user="${3:-$apache_site_name}"
  apache_site_group="${4:-$apache_site_user}"
  apache_site_config="/etc/apache2/sites-available/$apache_site_name"
  cgi_apache_path="/cgi-bin/"
  cgi_system_path="$apache_site_path/.cgi-bin/"
  # Create the /.cgi-bin/ directory and set permissions for SuExec.
  $SUDO mkdir -p "$cgi_system_path"
  $SUDO chmod 0755 "$cgi_system_path"
  # Define a new virtual host with mod_fastcgi configured to use SuExec.
  code_block=$( cat <<-EOD
<IfModule mod_fastcgi.c>
  FastCgiWrapper /usr/lib/apache2/suexec
  FastCgiConfig  -pass-header HTTP_AUTHORIZATION -autoUpdate -killInterval 120 -idle-timeout 30
</IfModule>

<VirtualHost *:80>
  DocumentRoot ${apache_site_path}

  LogLevel debug
  ErrorLog /var/log/apache2/error.${apache_site_name}.log
  CustomLog /var/log/apache2/access.${apache_site_name}.log combined

  SuexecUserGroup ${apache_site_user} ${apache_site_group}
  ScriptAlias ${cgi_apache_path} ${cgi_system_path}

  # Do not use kernel sendfile to deliver files to the client.
  EnableSendfile Off

  <Directory ${apache_site_path}>
    Options All
    AllowOverride All
  </Directory>
EOD
  )
  # Is PHP required?
  if [ ! -z "$PHP" ]; then
    cgi_action="php-fcgi"
    code_block=$( cat <<-EOD
${code_block}

  <IfModule mod_fastcgi.c>
    <Location ${cgi_apache_path}${cgi_action}>
      SetHandler fastcgi-script
      Options +ExecCGI +FollowSymLinks
      Order Allow,Deny
      Allow from all
    </Location>
    AddHandler ${cgi_action} .php
    Action     ${cgi_action} ${cgi_apache_path}${cgi_action}
  </IfModule>
EOD
    )
    $SUDO cat > "$cgi_system_path$cgi_action" <<-EOD
#!/bin/bash

export PHP_FCGI_CHILDREN=4
export PHP_FCGI_MAX_REQUESTS=200

export PHPRC="${cgi_system_path}php.ini"

exec ${PHP}
EOD
    $SUDO chmod 0755 "$cgi_system_path$cgi_action"
  fi
  code_block=$( cat <<-EOD
${code_block}
</VirtualHost>
EOD
  )
  # Write site configuration to Apache.
  echo "$code_block" | $SUDO tee "$apache_site_config" > /dev/null
  # Configure permissions for /.cgi-bin/ and SuExec.
  $SUDO chown -R "$apache_site_user":"$apache_site_group" "$cgi_system_path"
  # Update SuExec to accept the new document root for this website.
  grep "$apache_site_path" '/etc/apache2/suexec/www-data' > /dev/null || \
    ( $SUDO sed -e '1s#^#'"$apache_site_path""\n"'#' -i '/etc/apache2/suexec/www-data' > /dev/null )
}

# Restart the Apache server and reload with new configuration.
apache-restart() {
  $SUDO service apache2 restart
}

# }}}

# {{{ MySQL

# Create a database if one doesn't already exist.
mysql-database-create() {
  mysql -u root -e "CREATE DATABASE IF NOT EXISTS \`$1\` CHARACTER SET ${2:-utf8} COLLATE '${3:-utf8_general_ci}'"
}

# Restore a MySQL database from an archived backup.
mysql-database-restore() {
  local backups_database
  local backups_path
  local backups_file
  local tables_length
  backups_database="$1"
  backups_path="$2"
  if [ -d "$backups_path" ]; then
    tables_length=$( mysql -u root --skip-column-names -e "USE '$backups_database'; SHOW TABLES" | wc -l )
    if [ "$tables_length" -lt 1 ]; then
      backups_file=$( find "$backups_path" -maxdepth 1 -type f -regextype posix-basic -regex '^.*[0-9]\{8\}-[0-9]\{4\}.tar.bz2$' | \
        sort -g | \
        tail -1 )
      if [ ! -z "$backups_file" ]; then
        tar -xjf "$backups_file" -O | mysql -u root "$backups_database"
      fi
    fi
  fi
}

# Allow remote passwordless 'root' access for anywhere.
# This is only a good idea if the box is configured in 'Host-Only' network mode.
mysql-remote-access-allow() {
  mysql -u root -e "GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' IDENTIFIED BY '' WITH GRANT OPTION; FLUSH PRIVILEGES;"
  $SUDO sed -e 's#127.0.0.1#0.0.0.0#g' -i '/etc/mysql/my.cnf'
}

# Restart the MySQL server and reload with new configuration.
mysql-restart() {
  $SUDO service mysql restart
}

# }}}

# {{{ RubyGems

# Perform an unattended installation of package(s).
ruby-gems-install() {
  $SUDO gem install --no-ri --no-rdoc $*
}

# }}}

# {{{ NPM (Node Package Manager)

# Perform an unattended **global** installation of package(s).
npm-packages-install() {
  $SUDO npm config set yes true
  $SUDO npm install -g $*
}

# }}}

# {{{ GitHub

# Download and install RubyGems from GitHub.
github-gems-install() {
  local clone_path
  local configuration
  which 'git' >/dev/null || apt-packages-install 'git-core'
  which 'gem' >/dev/null || {
    echo 'Please install RubyGems to continue.' 1>&2
    exit 1
  }
  for repository in "$@"; do
    configuration=(${repository//@/"${IFS}"})
    clone_path="$( mktemp -d -t 'github-'$( echo "${configuration[0]}" | sed -e 's#[^[:alnum:]]\+#-#g' )'-XXXXXXXX' )"
    git clone "git://github.com/${configuration[0]}" "$clone_path"
    (                                                   \
      cd "$clone_path"                               && \
      git checkout "${configuration[1]:-master}"     && \
      gem build *.gemspec                            && \
      ruby-gems-install *.gem                           \
    )
    rm -Rf "$clone_path"
  done
}

# }}}