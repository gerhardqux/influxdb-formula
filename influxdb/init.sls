{% from "influxdb/map.jinja" import influxdb with context %}

{## Influx uses HTTP a lot, we need curl to create databases ##}
{## We may need openssl to generate a random password ##}
influxdb_deps:
  pkg.installed:
    - names:
      - curl
      - openssl

{## The influx package may be installed directly from a url, ##}
{## or from a repository ##}

{% if influxdb.install_method == 'repo' %}
influxdb_install:
  pkg.installed:
    - name: influxdb

{% elif influxdb.install_method == 'url' %}
influxdb_package:
  file.managed:
    - name: /root/{{ influxdb.filename }}
    - source: http://s3.amazonaws.com/influxdb/{{ influxdb.filename }}
    - source_hash: sha256={{ influxdb.filename_sha256 }}
  require:
    - pkg: influx_deps

influxdb_install:
  pkg.installed:
    - sources:
      - influxdb: /root/{{ influxdb.filename }}
    - require:
      - file: influxdb_package
{% endif %}

influxdb_datadir:
  file.directory:
    - name: /var/lib/influxdb
    - owner: influxdb
    - group: influxdb
    - mode: 755

influxdb_confdir:
  file.directory:
    - name: /etc/influxdb
    - owner: root
    - group: root
    - mode: 755

influxdb_config:
  file.managed:
    - name: /etc/influxdb/config.toml
    - source: salt://influxdb/files/config.toml.jinja
    - user: root
    - group: root
    - mode: 644
    - template: jinja

influxdb_systemd_service:
  file.managed:
    - name: /etc/systemd/system/influxdb.service
    - source: salt://influxdb/files/influxdb.service
    - user: root
    - group: root
    - mode: 755

influxdb_systemd_daemon_reload:
  cmd.run:
    - name: systemctl daemon-reload

influxdb_user:
  user.present:
    - name: influxdb
    - fullname: InfluxDB Service User
    - shell: /bin/bash
    - home: /opt/influxdb

influxdb_log:
  file.directory:
    - name: {{ influxdb.logging.directory }}
    - user: influxdb
    - group: influxdb
    - mode: 755

influxdb_logrotate:
  file.managed:
    - name: /etc/logrotate.d/influxdb
    - source: salt://influxdb/files/logrotate.conf.jinja
    - template: jinja
    - user: root
    - group: root
    - mode: 644
    - watch:
      - file: influxdb_log

influxdb_running:
  service.running:
    - name: influxdb
    - enable: True
    - watch:
      - pkg: influxdb_install
      - file: influxdb_config
    - require:
      - pkg: influxdb_install
      - file: influxdb_config

{## If influxdb is not responsive, wait 5 seconds ##}
influxdb_responsive:
  cmd.run:
    - name: sleep 5
    - unless: curl 'http://localhost:8086/' 
    - require:
      - service: influxdb

{## Set the cluster_admin password from pillar, ##}
{## or generate a random pwd, if 'root' is set. ##}
influx_set_root_pwd:
  cmd.script:
    - name: salt://influxdb/files/set_root_pwd
    - template: jinja
    - unless: curl 'http://localhost:8086/cluster_admins?u=root&p=root'  | grep Invalid
  require:
    - cmd: influxdb_responsive

{## Create all databases and its users ##}
{% for db, dbctx in influxdb.databases.iteritems() %}
influx_create_db_{{ db }}:
  cmd.script:
    - source: salt://influxdb/files/create_database
    - name: create_database {{ db }}
    - unless: curl --netrc-file /root/.influxdbpwd 'http://localhost:8086/db?pretty=true'  | grep '"{{ db }}"'
  require:
    - cmd: influxdb_set_root_pwd

{% for user, pass in dbctx.users.iteritems() %}
influx_create_db_{{ db }}_user_{{ user }}:
  cmd.script:
    - source: salt://influxdb/files/create_user
    - name: create_user {{ db }} {{ user }} {{ pass }}
    - unless: curl --netrc-file /root/.influxdbpwd 'http://localhost:8086/db/{{ db }}/users?pretty=true'  | grep '"{{ user }}"'
  require:
    - cmd: influx_create_db_{{ db }}
{% endfor %}

{%- endfor %}

