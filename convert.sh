#!/bin/bash

# Script to convert Docker Compose to Kubernetes manifests using kompose
# - Uses compose.yaml in the current folder
# - Converts .conf files to ConfigMaps
# - Converts .key and .crt files to Secrets

set -e

COMPOSE_DIR="$1"
OUTPUT_BASE_DIR="$COMPOSE_DIR/k8s-manifests"

# Find all directories (including COMPOSE_DIR itself) containing a compose.yaml or docker-compose.yaml
mapfile -t COMPOSE_FOLDERS < <(find "$COMPOSE_DIR" -type f \( -name "compose.yaml" -o -name "docker-compose.yaml" \) -exec dirname {} \; | sort -u)

process_folder() {
    local FOLDER="$1"
    # Compose file in this folder
    if [ -f "$FOLDER/compose.yaml" ]; then
        COMPOSE_FILE="$FOLDER/compose.yaml"
    elif [ -f "$FOLDER/docker-compose.yaml" ]; then
        COMPOSE_FILE="$FOLDER/docker-compose.yaml"
    else
        return
    fi

    # Output directory mirrors the structure under k8s-manifests
    if [ "$FOLDER" = "$COMPOSE_DIR" ]; then
        OUTPUT_DIR="$OUTPUT_BASE_DIR"
    else
        DIR_NAME="$(basename "$FOLDER")"
        OUTPUT_DIR="$OUTPUT_BASE_DIR/$DIR_NAME"
    fi
    mkdir -p "$OUTPUT_DIR"

    # Export these variables for use in the rest of the script
    export COMPOSE_FILE
    export COMPOSE_DIR="$FOLDER"
    export OUTPUT_DIR

    # --- Begin main conversion logic (copied from below) ---

    if [ ! -f "$COMPOSE_FILE" ]; then
        echo "❌ $COMPOSE_FILE not found in current directory."
        exit 1
    fi

    # Ensure kompose is installed
    if ! command -v kompose &> /dev/null; then
        echo "❌ Kompose is not installed. Please install it first."
        exit 1
    fi

    # Ensure kubectl is installed
    if ! command -v kubectl &> /dev/null; then
        echo "❌ kubectl is not installed. Please install it first."
        exit 1
    fi

    mkdir -p "$OUTPUT_DIR"

    # Step 1: Convert only YAML files (ignore other extensions)
    # Find all YAML files (compose.yaml or docker-compose.yaml) in the folder
    if [[ "$COMPOSE_FILE" == *.yaml || "$COMPOSE_FILE" == *.yml ]]; then
        kompose convert -f "$COMPOSE_FILE" -o "$OUTPUT_DIR"/
    else
        echo "⚠️  Skipping non-YAML compose file: $COMPOSE_FILE"
    fi

    echo "✅ Kompose conversion complete."

    # Step 2: Process .conf and .ini files into ConfigMaps
    for conf in "$COMPOSE_DIR"/*.conf "$COMPOSE_DIR"/*.ini; do
        [ -f "$conf" ] || continue
        name=$(basename "$conf")
        name_noext="${name%.*}"
        kubectl create configmap "$name_noext-config" --from-file="$conf" --dry-run=client -o yaml > "$OUTPUT_DIR/${name_noext}-configmap.yaml"
        echo "✅ Created ConfigMap manifest for $conf"
    done

    # Step 3: Process .key and .crt files into Secrets
    for sec in "$COMPOSE_DIR"/*.key "$COMPOSE_DIR"/*.crt; do
        [ -f "$sec" ] || continue
        name=$(basename "$sec")
        ext="${name##*.}"
        base="${name%.*}"
        secret_name="${base}-${ext}-secret"
        kubectl create secret generic "$secret_name" --from-file="$sec" --dry-run=client -o yaml > "$OUTPUT_DIR/${secret_name}.yaml"
        echo "✅ Created Secret manifest for $sec"
    done

    # Step 4: Sequentially patch pod manifests: replace all volumes and volumeMounts for .conf/.key/.crt with correct ConfigMap/Secret names
    for yml in "$OUTPUT_DIR"/*-pod.yaml; do
        [ -e "$yml" ] || continue

        # Find and patch all persistentVolumeClaim volumes referencing .conf, .key, or .crt files
        mapfile -t pvcvols < <(yq '.spec.volumes[]? | select(.persistentVolumeClaim) | .name' "$yml" | tr -d '"')
        for v in "${pvcvols[@]}"; do
            # Find all mountPaths for this volumeMount
            mapfile -t mpaths < <(yq '.spec.containers[].volumeMounts[]? | select(.name == "'"$v"'") | .mountPath' "$yml" | tr -d '"')
            for mpath in "${mpaths[@]}"; do
                base=$(basename "$mpath")
                ext="${base##*.}"
                if [[ "$mpath" == *.conf || "$mpath" == *.ini ]]; then
                    cfgname="${base%.*}-config"
                    # Remove old volume
                    yq -i 'del(.spec.volumes[] | select(.name == "'"$v"'"))' "$yml"
                    pvc_file="$OUTPUT_DIR/${v}-persistentvolumeclaim.yaml"
                    if [ -f "$pvc_file" ]; then
                        rm -f "$pvc_file"
                        echo "🗑️  Deleted $pvc_file"
                    fi
                    yq -i '.spec.volumes += [{"name": "'$cfgname'", "configMap": {"name": "'$cfgname'"}}]' "$yml"
                    yq -i '(.spec.containers[].volumeMounts[] | select(.name == "'"$v"'")) |= .name = "'$cfgname'" | (.spec.containers[].volumeMounts[] | select(.name == "'$cfgname'")) |= .subPath = "'$base'"' "$yml"
                elif [[ "$mpath" == *.key || "$mpath" == *.crt ]]; then
                    secname="${base%.*}-${ext}-secret"
                    yq -i 'del(.spec.volumes[] | select(.name == "'"$v"'"))' "$yml"
                    pvc_file="$OUTPUT_DIR/${v}-persistentvolumeclaim.yaml"
                    if [ -f "$pvc_file" ]; then
                        rm -f "$pvc_file"
                        echo "🗑️  Deleted $pvc_file"
                    fi
                    yq -i '.spec.volumes += [{"name": "'$secname'", "secret": {"secretName": "'$secname'"}}]' "$yml"
                    yq -i '(.spec.containers[].volumeMounts[] | select(.name == "'"$v"'")) |= .name = "'$secname'" | (.spec.containers[].volumeMounts[] | select(.name == "'$secname'")) |= .subPath = "'$base'"' "$yml"
                fi
            done
        done

        # Remove any persistentVolumeClaim volumes that reference .conf, .key, or .crt
        mapfile -t pvcvols < <(yq '.spec.volumes[]? | select(.persistentVolumeClaim) | .name' "$yml" | tr -d '"')
        for v in "${pvcvols[@]}"; do
            mpath=$(yq '.spec.containers[].volumeMounts[]? | select(.name == "'"$v"'") | .mountPath' "$yml" | tr -d '"')
            if [[ "$mpath" == *.conf || "$mpath" == *.key || "$mpath" == *.crt ]]; then
                yq -i 'del(.spec.volumes[] | select(.name == "'"$v"'"))' "$yml"
            fi
        done
    done

    echo "All done! Check the $OUTPUT_DIR directory for generated manifests."
    # --- End main conversion logic ---
}

for FOLDER in "${COMPOSE_FOLDERS[@]}"; do
    process_folder "$FOLDER"
done

if [ ! -f "$COMPOSE_FILE" ]; then
    echo "❌ $COMPOSE_FILE not found in current directory."
    exit 1
fi

# Ensure kompose is installed
if ! command -v kompose &> /dev/null; then
    echo "❌ Kompose is not installed. Please install it first."
    exit 1
fi

# Ensure kubectl is installed
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl is not installed. Please install it first."
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

# Step 1: Convert compose.yaml to Kubernetes manifests
kompose convert -f "$COMPOSE_FILE" -o "$OUTPUT_DIR"/

echo "✅ Kompose conversion complete."


# Step 2: Process .conf and .ini files into ConfigMaps
for conf in "$COMPOSE_DIR"/*.conf "$COMPOSE_DIR"/*.ini; do
    [ -f "$conf" ] || continue
    name=$(basename "$conf")
    name_noext="${name%.*}"
    kubectl create configmap "$name_noext-config" --from-file="$conf" --dry-run=client -o yaml > "$OUTPUT_DIR/${name_noext}-configmap.yaml"
    echo "✅ Created ConfigMap manifest for $conf"
done

# Step 3: Process .key and .crt files into Secrets
for sec in "$COMPOSE_DIR"/*.key "$COMPOSE_DIR"/*.crt; do
    [ -f "$sec" ] || continue
    name=$(basename "$sec")
    ext="${name##*.}"
    base="${name%.*}"
    secret_name="${base}-${ext}-secret"
    kubectl create secret generic "$secret_name" --from-file="$sec" --dry-run=client -o yaml > "$OUTPUT_DIR/${secret_name}.yaml"
    echo "✅ Created Secret manifest for $sec"
done


# Step 4: Patch output manifests to use generated ConfigMap/Secret YAMLs for .conf, .key, .crt

# Step 4: Patch output manifests to use generated ConfigMap/Secret YAMLs for .conf, .key, .crt and remove all related PVCs

# Step 4: Sequentially patch pod manifests: replace all volumes and volumeMounts for .conf/.key/.crt with correct ConfigMap/Secret names
for yml in "$OUTPUT_DIR"/*-pod.yaml; do
    [ -e "$yml" ] || continue

    # Find and patch all persistentVolumeClaim volumes referencing .conf, .key, or .crt files
    mapfile -t pvcvols < <(yq '.spec.volumes[]? | select(.persistentVolumeClaim) | .name' "$yml" | tr -d '"')
    for v in "${pvcvols[@]}"; do
        # Find all mountPaths for this volumeMount
        mapfile -t mpaths < <(yq '.spec.containers[].volumeMounts[]? | select(.name == "'"$v"'") | .mountPath' "$yml" | tr -d '"')
        for mpath in "${mpaths[@]}"; do
            base=$(basename "$mpath")
            ext="${base##*.}"
            if [[ "$mpath" == *.conf || "$mpath" == *.ini ]]; then
                cfgname="${base%.*}-config"
                # Remove old volume
                # Delete the old volume from the pod manifest
                yq -i 'del(.spec.volumes[] | select(.name == "'"$v"'"))' "$yml"
                # Also delete the corresponding persistent volume YAML file if it exists
                pvc_file="$OUTPUT_DIR/${v}-persistentvolumeclaim.yaml"
                if [ -f "$pvc_file" ]; then
                    rm -f "$pvc_file"
                    echo "🗑️  Deleted $pvc_file"
                fi
                # Add ConfigMap volume
                yq -i '.spec.volumes += [{"name": "'$cfgname'", "configMap": {"name": "'$cfgname'"}}]' "$yml"
                # Update all volumeMounts for this volume to use new name and subPath
                yq -i '(.spec.containers[].volumeMounts[] | select(.name == "'"$v"'")) |= .name = "'$cfgname'" | (.spec.containers[].volumeMounts[] | select(.name == "'$cfgname'")) |= .subPath = "'$base'"' "$yml"
            elif [[ "$mpath" == *.key || "$mpath" == *.crt ]]; then
                secname="${base%.*}-${ext}-secret"
                # Delete the old volume from the pod manifest
                yq -i 'del(.spec.volumes[] | select(.name == "'"$v"'"))' "$yml"
                # Also delete the corresponding persistent volume YAML file if it exists
                pvc_file="$OUTPUT_DIR/${v}-persistentvolumeclaim.yaml"
                if [ -f "$pvc_file" ]; then
                    rm -f "$pvc_file"
                    echo "🗑️  Deleted $pvc_file"
                fi
                yq -i '.spec.volumes += [{"name": "'$secname'", "secret": {"secretName": "'$secname'"}}]' "$yml"
                yq -i '(.spec.containers[].volumeMounts[] | select(.name == "'"$v"'")) |= .name = "'$secname'" | (.spec.containers[].volumeMounts[] | select(.name == "'$secname'")) |= .subPath = "'$base'"' "$yml"
            fi
        done
    done

    # Remove any persistentVolumeClaim volumes that reference .conf, .key, or .crt
    mapfile -t pvcvols < <(yq '.spec.volumes[]? | select(.persistentVolumeClaim) | .name' "$yml" | tr -d '"')
    for v in "${pvcvols[@]}"; do
        # Try to find if this PVC was used for .conf/.key/.crt
        mpath=$(yq '.spec.containers[].volumeMounts[]? | select(.name == "'"$v"'") | .mountPath' "$yml" | tr -d '"')
        if [[ "$mpath" == *.conf || "$mpath" == *.key || "$mpath" == *.crt ]]; then
            yq -i 'del(.spec.volumes[] | select(.name == "'"$v"'"))' "$yml"
        fi
    done
done

echo "All done! Check the $OUTPUT_DIR directory for generated manifests."
