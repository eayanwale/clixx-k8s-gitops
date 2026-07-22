#!/usr/bin/env python

import boto3, sys, fileinput
from pathlib import Path

session = boto3.Session(
    profile_name='stackprog-dev',
    region_name='us-east-1'
)
client = session.client('ssm')

def get_params():
    params = ['dbname', 'db_user', 'db_password', 'db_host']
    values = []

    try:
        for param in params:

            name = f"/stack/clixx/{param}"
            # name = "/stack/clixx/dbname"
            print(name)

            value = client.get_parameter(
                Name=name,
                WithDecryption = True
            )['Parameter']['Value']
            values.append(value)

    except client.exceptions.ParameterNotFound:
        value = None

    print("")
    return values

def replace_config():
    file_path = "/var/www/html/wp-config.php"
    search_strings = ['DB_NAME', 'DB_USER', 'DB_PASSWORD', 'DB_HOST']
    values = get_params()
    replacements = dict(zip(search_strings, values))

    with fileinput.input(file_path, inplace=True) as file:
        for line in file:
            for string, value in replacements.items():
                if string in line:
                    line = f"define( '{string}', '{value}' );\n"
            sys.stdout.write(line)

if __name__ == "__main__":
    print("Getting parameters...")
    output = get_params()
    print("Parameters loaded!")
    print(f"{output}\n")

    print("Running replacements...")
    replace_config()
    print("All secrets replaced!\n")