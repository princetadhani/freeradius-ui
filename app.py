import os
import subprocess
import ipaddress
from flask import Flask, render_template, request, jsonify

app = Flask(__name__)
app.secret_key = "radius_admin_final"

BASE_DIR = "/etc/freeradius/3.0"
COA_DIR = os.path.join(BASE_DIR, "coa")
LOG_FILE = "/var/log/freeradius/radius.log"

# --- Security Helper ---
def get_safe_path(base_directory, user_path):
    """
    Resolves the absolute path and ensures it stays strictly within the base_directory.
    Prevents Directory Traversal (e.g., ../../../../etc/shadow)
    """
    if not user_path:
        raise ValueError("No path provided.")
        
    full_path = os.path.abspath(os.path.join(base_directory, user_path))
    
    if not full_path.startswith(os.path.abspath(base_directory)):
        raise ValueError("Access Denied: Path Traversal Detected.")
        
    return full_path

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
    try:
        # SECURE: Path traversal check
        full_path = get_safe_path(BASE_DIR, path)
        with open(full_path, 'r') as f:
            return jsonify({"content": f.read(), "path": path})
    except ValueError as ve:
        return jsonify({"error": str(ve)}), 403
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/save', methods=['POST'])
def save():
    data = request.get_json()
    path = data.get('filepath')
    content = data.get('content')
    
    try:
        # SECURE: Path traversal check
        full_path = get_safe_path(BASE_DIR, path)
        
        # Write natively! No sudo cp needed because of correct Linux Group permissions
        with open(full_path, 'w') as f:
            f.write(content)

        # Check config syntax first
        check = subprocess.run(["sudo", "freeradius", "-C"], capture_output=True, text=True)
        if check.returncode != 0:
            return jsonify({"status": "error", "message": "Config test failed! Revert changes.", "output": check.stderr}), 400

        subprocess.run(["sudo", "systemctl", "restart", "freeradius"])
        return jsonify({"status": "success"})
    except ValueError as ve:
        return jsonify({"status": "error", "message": str(ve)}), 403
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
    
    if not filename.endswith('.txt'): 
        filename += '.txt'
    
    try:
        # SECURE: Path traversal check
        full_path = get_safe_path(COA_DIR, filename)
        with open(full_path, 'w') as f:
            f.write(content)
        return jsonify({"status": "success"})
    except ValueError as ve:
        return jsonify({"status": "error", "message": str(ve)}), 403
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500

@app.route('/coa/delete/<filename>', methods=['DELETE'])
def delete_coa(filename):
    try:
        # SECURE: Path traversal check
        full_path = get_safe_path(COA_DIR, filename)
        os.remove(full_path)
        return jsonify({"status": "success"})
    except ValueError as ve:
        return jsonify({"status": "error", "message": str(ve)}), 403
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500

@app.route('/coa/send', methods=['POST'])
def send_coa():
    data = request.get_json()
    req_type = data.get('req_type', 'coa') # coa or disconnect
    nas_ip = data.get('nas_ip')
    secret = data.get('secret')
    filename = data.get('filename')

    # SECURE: Input Validation for IP Address
    try:
        ipaddress.ip_address(nas_ip)
    except ValueError:
        return jsonify({"status": "error", "message": "Invalid NAS IP address format."}), 400
        
    # SECURE: Ensure request type is exactly what we expect
    if req_type not in ['coa', 'disconnect']:
        return jsonify({"status": "error", "message": "Invalid request type."}), 400

    try:
        # SECURE: Path traversal check for the filename being sent
        safe_coa_file = get_safe_path(COA_DIR, filename)
        
        cmd = [
            "sudo", "radclient", "-f", safe_coa_file,
            "-x", "-r", "1", nas_ip, req_type, secret
        ]
        
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        return jsonify({
            "status": "success" if result.returncode == 0 else "error",
            "output": result.stdout,
            "error": result.stderr
        })
    except ValueError as ve:
        return jsonify({"status": "error", "message": str(ve)}), 403
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

        return jsonify({"status": state, "raw": status})

    except Exception as e:
        return jsonify({"status": "unknown", "error": str(e)})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8888, debug=True)