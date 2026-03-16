import os
import subprocess
from flask import Flask, render_template, request, jsonify

app = Flask(__name__)
app.secret_key = "radius_admin_final"

BASE_DIR = "/etc/freeradius/3.0"
COA_DIR = os.path.join(BASE_DIR, "coa")

LOG_FILE = "/var/log/freeradius/radius.log"

# Ensure CoA directory exists
try:
    if not os.path.exists(COA_DIR):
        os.makedirs(COA_DIR, exist_ok=True)
except Exception as e:
    print(f"Warning: Could not create CoA directory: {e}")

def get_directory_structure(rootdir):
    nodes = []
    try:
        entries = sorted(os.scandir(rootdir), key=lambda e: (not e.is_dir(), e.name))
        for entry in entries:
            rel_path = os.path.relpath(entry.path, BASE_DIR)
            node = {"name": entry.name, "path": rel_path, "is_dir": entry.is_dir()}
            if entry.is_dir():
                node["children"] = get_directory_structure(entry.path)
            nodes.append(node)
    except Exception: pass
    return nodes

@app.route('/')
def index():
    structure = get_directory_structure(BASE_DIR)
    return render_template('editor.html', structure=structure)

@app.route('/get_file_content')
def get_file_content():
    path = request.args.get('path')
    full_path = os.path.join(BASE_DIR, path)
    try:
        with open(full_path, 'r') as f:
            return jsonify({"content": f.read(), "path": path})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/save', methods=['POST'])
def save():
    data = request.get_json()
    path = data.get('filepath')
    content = data.get('content')
    full_path = os.path.join(BASE_DIR, path)
    try:
        with open(full_path, 'w') as f:
            f.write(content)
        os.system("sudo systemctl restart freeradius")
        return jsonify({"status": "success"})
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500

# --- CoA Manager Routes ---

@app.route('/coa')
def coa_manager():
    structure = get_directory_structure(COA_DIR)
    return render_template('coa.html', structure=structure)

@app.route('/coa/save', methods=['POST'])
def save_coa():
    data = request.get_json()
    filename = data.get('filename')
    content = data.get('content')
    if not filename.endswith('.txt'): filename += '.txt'
    
    full_path = os.path.join(COA_DIR, filename)
    try:
        with open(full_path, 'w') as f:
            f.write(content)
        return jsonify({"status": "success"})
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500

@app.route('/coa/delete/<filename>', methods=['DELETE'])
def delete_coa(filename):
    try:
        os.remove(os.path.join(COA_DIR, filename))
        return jsonify({"status": "success"})
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500

@app.route('/coa/send', methods=['POST'])
def send_coa():
    data = request.get_json()
    req_type = data.get('req_type', 'coa') # coa or disconnect
    
    cmd = [
        "sudo", "radclient", "-f", os.path.join(COA_DIR, data['filename']),
        "-x", "-r", "1", data['nas_ip'], req_type, data['secret']
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        return jsonify({
            "status": "success" if result.returncode == 0 else "error",
            "output": result.stdout,
            "error": result.stderr
        })
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500

#Logs Logic
@app.route("/logs")
def logs():
    return render_template("logs.html")


@app.route("/logs/tail")
def logs_tail():

    offset = int(request.args.get("offset", 0))

    try:
        with open(LOG_FILE, "r") as f:

            f.seek(0, os.SEEK_END)
            file_size = f.tell()

            if offset > file_size:
                offset = 0

            f.seek(offset)

            data = f.read()

            new_offset = f.tell()

        return jsonify({
            "content": data,
            "offset": new_offset,
            "size": file_size
        })

    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/radius_status')
def radius_status():
    try:
        result = subprocess.run(
            ["systemctl", "is-active", "freeradius"],
            capture_output=True,
            text=True
        )

        status = result.stdout.strip()

        if status == "active":
            state = "running"
        elif status == "failed":
            state = "failed"
        elif status in ["inactive", "deactivating"]:
            state = "stopped"
        else:
            state = "unknown"

        return jsonify({
            "status": state,
            "raw": status
        })

    except Exception as e:
        return jsonify({
            "status": "unknown",
            "error": str(e)
        })

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8888, debug=True)