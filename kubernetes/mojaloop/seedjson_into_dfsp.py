import argparse
import json
import logging
import requests
import sys

from datetime import datetime

_logger = logging.getLogger(__name__)
_logger.setLevel(logging.DEBUG)
_logger.addHandler(logging.StreamHandler(sys.stdout))
_logger.addHandler(logging.FileHandler('seed_ml_accounts.log'))

def init_args():
    parser = argparse.ArgumentParser(description='Seed Accounts from json into DFSP.')
    parser.add_argument('json_path', help='Path to JSON File')
    parser.add_argument('dfsp_id', help='DFSP Id in ML')
    parser.add_argument('dfsp_url', help='DFSP URL Backend URL')
    parser.add_argument('ml_als_url', help='ML Account Lookup Service URL')
    parser.add_argument('--currency', default='USD', help='Currency (default: USD)')
    parser.add_argument('--seed-to-backend', default='true', choices=['true', 'false'], help='Flag to select whether seed the data into backend (default: true)')
    parser.add_argument('--seed-to-als', default='true', choices=['true', 'false'], help='Flag to select whether seed the participants into ALS (default: true)')

    args = parser.parse_args()
    return args, parser

def read_json_from_file(json_path : str):
    json_list = []
    with open(json_path, 'r') as f:
        json_obj = json.load(f)
        if not json_obj:
            pass
        elif isinstance(json_obj, list):
            json_list.extend(json_obj)
        elif isinstance(json_obj, dict):
            json_list.append(json_obj)
    return json_list

def seed_json_list(json_list : list, dfsp_id : str, dfsp_url : str, ml_als_url : str, seed_to_backend='true', seed_to_als='true', currency='USD'):
    for i, json in enumerate(json_list):
        try:
            seed_each_entry(
                i,
                json,
                dfsp_id,
                dfsp_url,
                ml_als_url,
                seed_to_backend=seed_to_backend,
                seed_to_als=seed_to_als,
                currency=currency
            )
        except Exception as e:
            _logger.error('Entry Number %d. Error Occured.', i, e)

def seed_each_entry(entry_no : int, entry : dict, dfsp_id : str, dfsp_url : str, ml_als_url : str, seed_to_backend='true', seed_to_als='true', currency='USD'):
    if seed_to_backend=='true':
        res = seed_each_entry_to_backend(entry_no, entry, dfsp_url)
    if seed_to_als=='true':
        res = seed_each_entry_to_als(entry_no, entry, dfsp_id, ml_als_url, currency=currency)
    return None

def seed_each_entry_to_backend(entry_no : int, entry : dict, dfsp_url : str):
    res = requests.post(
        dfsp_url.rstrip('/') + '/repository/parties',
        json=entry
    )
    if res.status_code in (200, 201, 202, 204):
        _logger.info('Entry Number %d is added to backend. Status Code: %d. Response: %s', entry_no, res.status_code, res.text if res.text else '-')
    else:
        _logger.error('Entry Number %d adding to backend error. Status Code: %d. Response: %s', entry_no, res.status_code, res.text if res.text else '-')
    return res

def seed_each_entry_to_als(entry_no : int, entry : dict, dfsp_id : str, ml_als_url : str, currency='USD'):
    participant_id_type = entry['idType']
    participant_id_value = entry['idValue']
    res = requests.post(
        ml_als_url.rstrip('/') + f'/participants/{participant_id_type}/{participant_id_value}',
        data=json.dumps({
            'fspId': dfsp_id,
            'currency': currency
        }),
        headers={
            'Content-Type': 'application/vnd.interoperability.participants+json;version=1.0',
            'Accept': 'application/vnd.interoperability.participants+json;version=1',
            'Date': datetime.utcnow().strftime('%a, %d %b %Y %H:%M:%S GMT'),
            'FSPIOP-Source': dfsp_id,
        },
    )
    if res.status_code in (200, 201, 202, 204):
        _logger.info('Entry Number %d is seeded to ALS. Status Code: %d. Response: %s', entry_no, res.status_code, res.text if res.text else '-')
    else:
        _logger.error('Entry Number %d adding to backend error. Status Code: %d. Response: %s', entry_no, res.status_code, res.text if res.text else '-')
    return res

if __name__ == '__main__':
    args, _ = init_args()
    _logger.info("JSON List reading")
    json_list = read_json_from_file(args.json_path)
    _logger.info("JSON List readed success")
    res = seed_json_list(
        json_list,
        args.dfsp_id,
        args.dfsp_url,
        args.ml_als_url,
        seed_to_backend=args.seed_to_backend,
        seed_to_als=args.seed_to_als,
        currency=args.currency
    )
    _logger.info("All entries seed success")
