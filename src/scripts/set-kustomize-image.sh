# set-kustomize-image.sh
#
# Included by the deploy-with-kustomize command. Updates kustomization.yaml in
# place so kubectl apply -k can deploy the built image tag.
#
# Orb parameters (substituted when the orb is packed):
#   kustomize-path        Directory containing kustomization.yaml
#   kustomize-image-name  Kustomize images[].name to match (default: app)
#   image-name            Full image reference without tag (usually the ECR URL)
#
# Runtime environment:
#   DOCKER_TAG            Image tag from the determine-docker-tag command
#
# Matching (when images: already exists):
#   An entry matches if any of these are true:
#     - images[].name equals kustomize-image-name
#     - images[].name equals image-name
#     - images[].newName equals image-name
#   The matched entry's newTag is updated; other fields are left unchanged.
#
# When no images: section exists (typical Goodway overlays):
#   Appends:
#     images:
#       - name: <image-name>
#         newTag: <DOCKER_TAG>
#
# When images: exists but nothing matches:
#   Appends a new list entry. Registry paths (image-name contains "/") use the
#   short-name pattern: name + newName + newTag. Otherwise name + newTag only.
#
# Examples:
#   Goodway (no images section):
#     image-name=967710342214.dkr.ecr.us-east-1.amazonaws.com/microservice/my-app
#     -> adds images[].name with full ECR path and newTag
#
#   ai-enablement-aws-infra (existing images section):
#     images[].name=fastapi-demo, newName=<ECR URL>, newTag=latest
#     image-name=<same ECR URL>
#     -> updates newTag only (matched via newName)
#
#   Match by short name:
#     kustomize-image-name=fastapi-demo
#     -> updates the entry whose images[].name is fastapi-demo
cd <<parameters.kustomize-path>>
export KUSTOMIZE_IMAGE_NAME='<<parameters.kustomize-image-name>>'
export IMAGE_NAME='<<parameters.image-name>>'
export DOCKER_TAG="$DOCKER_TAG"
python3 <<'PY'
"""Update kustomization.yaml images for deploy-with-kustomize."""
import os
import re

path = "kustomization.yaml"
kustomize_image_name = os.environ["KUSTOMIZE_IMAGE_NAME"]
image_name = os.environ["IMAGE_NAME"]
docker_tag = os.environ["DOCKER_TAG"]
match_keys = {kustomize_image_name, image_name}

with open(path, encoding="utf-8") as f:
    lines = f.readlines()


def line_indent(line):
    return len(line) - len(line.lstrip(" "))


images_idx = next(
    (i for i, line in enumerate(lines) if re.match(r"^images:\s*(\S.*)?$", line)),
    None,
)


def append_new_images_section():
    """Add images section for overlays that do not define one yet."""
    lines.append("images:\n")
    lines.extend([
        f"  - name: {image_name}\n",
        f"    newTag: {docker_tag}\n",
    ])


def append_image_entry():
    """Append an images list item when the section exists but nothing matched."""
    if "/" in image_name:
        lines.extend([
            f"  - name: {kustomize_image_name}\n",
            f"    newName: {image_name}\n",
            f"    newTag: {docker_tag}\n",
        ])
    else:
        lines.extend([
            f"  - name: {image_name}\n",
            f"    newTag: {docker_tag}\n",
        ])


if images_idx is None:
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"
    append_new_images_section()
else:
    images_indent = line_indent(lines[images_idx])
    entry_start = None
    entry_name = None
    entry_new_name = None
    new_tag_idx = None
    matched = False

    for i in range(images_idx + 1, len(lines)):
        line = lines[i]
        stripped = line.strip()

        # End of images list when indentation returns to the images: key level.
        if stripped and not stripped.startswith("#") and line_indent(line) <= images_indent:
            break

        name_match = re.match(r"^(\s*)-\s+name:\s*(.+)\s*$", line)
        if name_match:
            # Finalize the previous entry when starting the next one.
            if entry_start is not None and (
                entry_name in match_keys or entry_new_name == image_name
            ):
                matched = True
                if new_tag_idx is not None:
                    indent = re.match(r"^(\s*)", lines[new_tag_idx]).group(1)
                    lines[new_tag_idx] = f"{indent}newTag: {docker_tag}\n"
                else:
                    item_indent = name_match.group(1) + "  "
                    lines.insert(i, f"{item_indent}newTag: {docker_tag}\n")
                break

            entry_start = i
            entry_name = name_match.group(2).strip()
            entry_new_name = None
            new_tag_idx = None
            continue

        if entry_start is not None:
            new_name_match = re.match(r"^\s+newName:\s*(.+)\s*$", line)
            if new_name_match:
                entry_new_name = new_name_match.group(1).strip()
            if re.match(r"^\s+newTag:\s*", line):
                new_tag_idx = i

    # Handle the last (or only) entry in the images list.
    if not matched and entry_start is not None and (
        entry_name in match_keys or entry_new_name == image_name
    ):
        matched = True
        if new_tag_idx is not None:
            indent = re.match(r"^(\s*)", lines[new_tag_idx]).group(1)
            lines[new_tag_idx] = f"{indent}newTag: {docker_tag}\n"
        else:
            item_indent = " " * (line_indent(lines[entry_start]) + 2)
            lines.insert(entry_start + 1, f"{item_indent}newTag: {docker_tag}\n")

    if not matched:
        append_image_entry()

with open(path, "w", encoding="utf-8") as f:
    f.writelines(lines)
PY
