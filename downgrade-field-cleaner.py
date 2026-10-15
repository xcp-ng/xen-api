#!/usr/bin/env python3
from argparse import ArgumentParser
import logging
import shutil
import subprocess
import sys
import os.path
import time
import xml.etree.ElementTree as ET

### README
#
# A helper script based on snapshot-fixer.py, that allows to downgrade xapi
# from a particular version (by dropping fields from the DB the old version
# won't recognize)
#
# The script needs to be run on the master host of the affected pool.
#
# Like snapshot-fixer.py it stops xapi (disabling HA first) while it edits the
# database, backs the database up, and can restore the backup.

xapi_db        = '/var/lib/xcp/state.db'
xapi_db_imm        = '/var/lib/xcp/state.db.imm'
xapi_db_backup = '/var/lib/xcp/state.db.downgrade.backup'

# DANGEROUS !!!!!!!!
# Which column in which table to drop - very version-dependent (both on the
# current version and on the version to be downgraded to)
XAPI_VERSION='26.1.21'
FIELDS_TO_DROP = {'host': ['downgrade_field']}
PACKAGE_LIST = ['xapi*', 'xenopsd*', 'forkexecd', 'xapi-rrd2csv', 'vhd-tool',
                'message-switch', 'qcow-stream-tool', 'rrdd-plugins', 'sm-cli',
                'varstored-guard', 'xcp-networkd', 'wsproxy', 'xcp-rrdd', 'squeezed']

def service_status(name):
    cmd = ['systemctl', 'is-active', name]
    r = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE
    )
    return r.stdout.strip()

def poke_service(name, cmd, check):
    end = time.time() + 15
    subprocess.run(['systemctl', cmd, name], check=True)
    while time.time() < end:
        if check(name):
            return
        time.sleep(2)
    raise TimeoutError(f'Could not {cmd} {name} service in time.')

def is_service_active(name):
    return service_status(name) == b'active'

def is_service_inactive(name):
    return service_status(name) in [b'inactive', b'failed']

def start_xapi(ha_enabled):
    logging.info('Starting up xapi...')
    try:
        poke_service('xapi', 'start', is_service_active)
    except TimeoutError:
        logging.error('Starting xapi timed out. Please make sure it\'s working by running `systemctl status xapi`')
        if ha_enabled:
            logging.error('HA was disabled and needs to be enabled back again manually. Please re-enable it by running `xe pool-ha-enable`')
        sys.exit(1)

def stop_xapi():
    logging.info('Shutting down xapi...')
    try:
        poke_service('xapi', 'stop', is_service_inactive)
    except TimeoutError:
        logging.error('Timed out, aborting')
        sys.exit(1)

def update_xapi():
    logging.info('Updating XAPI...')
    subprocess.run(['yum', 'update'] + PACKAGE_LIST, check=True)
    logging.info('XAPI updated...')
    return

def downgrade_xapi():
    logging.info('Downgrading XAPI...')
    subprocess.run(['yum', 'downgrade'] + PACKAGE_LIST, check=True)
    logging.info('XAPI downgraded...')
    return

def start_ha():
    logging.info('Enable HA...')
    end = time.time() + 30
    time.sleep(2)
    while time.time() < end:
        try:
            subprocess.run(['xe', 'pool-ha-enable'], check=True)
            logging.info('HA enabled...')
            return
        except subprocess.CalledProcessError:
            time.sleep(2)
    raise TimeoutError('Could not re-enable HA in time.')

def query_and_stop_ha():
    logging.info('Check HA...')

    def pool_list():
        return subprocess.run(
            [ 'xe', 'pool-list', '--minimal' ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )

    r = pool_list()
    if r.returncode != 0:
        logging.info('Xapi was down, bringing it up to check HA')
        start_xapi(False)
    while r.returncode != 0:
        r = pool_list()
        time.sleep(0.1)
    pool_uuid = r.stdout.strip().split()[-1].decode('utf-8')
    r = subprocess.run(
        [ 'xe', 'pool-param-get', 'param-name=ha-enabled', 'uuid=' + pool_uuid ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE
    )
    ha_enabled = r.stdout.strip() == b'true'
    if ha_enabled:
        logging.info('Disable HA...')
        subprocess.run(['xe', 'pool-ha-disable'], check=True)
    return ha_enabled


def clean_record(table, to_drop, row):
    for field in to_drop:
        if field in row.attrib:
            logging.info(
                f'Removing {table}.{field} from row {row.get("ref")}'
            )
            del row.attrib[field]

def regenerate_database(file):
    logging.info('Regenerating database...')
    tree = ET.parse(file)
    root = tree.getroot()
    tables = FIELDS_TO_DROP.keys()
    for table in root.findall('.//table'):
        name = table.get('name')
        if name not in tables:
            continue
        to_drop = FIELDS_TO_DROP[name]
        for row in table.findall('row'):
            clean_record(name, to_drop, row)
    return tree

def rewrite_database(original, to):
    tree = regenerate_database(original)
    with open(to, 'wb') as fixed:
        logging.info(f'Writing database to {to}')
        tree.write(fixed, encoding='UTF-8', xml_declaration=True)

def ensure_file_exists(path):
    if not os.path.isfile(path):
        logging.error(f'File {path} does not exist, and cannot continue; aborting.')
        sys.exit(1)

def ensure_file_missing(path):
    if os.path.isfile(path):
        logging.error(f'File {path} already exists, aborting. If you are sure you want to run the command again, please delete the file')
        sys.exit(1)

def copy_database(origin, to):
    shutil.copyfile(origin, to)

def dry_run(args):
    ensure_file_exists(xapi_db)
    ensure_supported_version()
    regenerate_database(xapi_db)

def restore(args):
    ensure_file_exists(xapi_db_backup)
    ha_enabled = query_and_stop_ha()
    stop_xapi()
    try:
        copy_database(xapi_db_backup, to=xapi_db)
    finally:
        update_xapi()
        start_xapi(ha_enabled)
        if ha_enabled:
            start_ha()

def downgrade(args):
    ensure_file_exists(xapi_db)
    ensure_file_missing(xapi_db_backup)
    ensure_supported_version()
    ha_enabled = query_and_stop_ha()
    stop_xapi()
    try:
        copy_database(xapi_db, to=xapi_db_backup)
        rewrite_database(xapi_db_backup, to=xapi_db)
        copy_database(xapi_db, to=xapi_db_imm)
    finally:
        downgrade_xapi()
        start_xapi(ha_enabled)
        if ha_enabled:
            start_ha()

def get_xapi_version():
    inventory = {}

    with open("/etc/xensource-inventory") as f:
        for line in f:
            if "=" in line:
                k, v = line.strip().split("=", 1)
                inventory[k] = v.strip("'")

    host_uuid = inventory.get("INSTALLATION_UUID")

    if not host_uuid:
        raise RuntimeError("INSTALLATION_UUID not found")

    r = subprocess.run(
        ['xe', 'host-param-get', 'param-name=software-version',
         'param-key=xapi_build', 'uuid=' + host_uuid],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    return r.stdout.strip().decode()

def ensure_supported_version():
    logging.info('Checking xapi version...')
    version = get_xapi_version()

    if version != XAPI_VERSION:
        print(
            f"ERROR: This version of downgrade-field-cleaner.py can only "
            f"downgrade xapi from {XAPI_VERSION}. "
            f"Detected version: {version}"
        )
        sys.exit(1)

def ensure_run_on_coordinator():
    with open("/etc/xensource/pool.conf") as f:
        for line in f:
            if line != "master":
                print("ERROR: script needs to run on the coordinator host")
                sys.exit(1)

def main():
    p = ArgumentParser(description='Drop fields unknown to older xapi from the database.')
    ps = p.add_subparsers(dest='cmd')
    ps.add_parser('dry-run', help='Prints fields to remove; does not stop xapi nor modify the database.').set_defaults(func=dry_run)
    ps.add_parser('restore-backup', help='Stops xapi, restores the backup, starts xapi.').set_defaults(func=restore)
    ps.add_parser('downgrade', help="Stops xapi, backs the database up, removes the fields, starts xapi.").set_defaults(func=downgrade)
    args = p.parse_args()
    if args.cmd is None:
        p.print_help()
        sys.exit(1)

    ensure_run_on_coordinator()
    logging.basicConfig()
    logging.getLogger().setLevel(logging.INFO)
    args.func(args)

if __name__ == '__main__':
    main()

