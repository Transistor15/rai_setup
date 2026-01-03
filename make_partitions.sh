#!/bin/bash

# Default source and destination devices
SOURCE="/dev/mmcblk0"
DESTINATION="/dev/nvme0n1"

# Function to show help message
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Clone partition structure from one disk to another and replicate file systems."
    echo
    echo "Options:"
    echo "  -s, --source      Source disk (default: /dev/mmcblk0)"
    echo "  -d, --destination Destination disk (default: /dev/nvme0n1)"
    echo "  -h, --help        Show this help message and exit"
    echo
    exit 0
}

# Parse command-line arguments
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -s|--source)
            SOURCE="$2"
            shift 2
            ;;
        -d|--destination)
            DESTINATION="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            ;;
    esac
done

# Confirm the operation with the user
echo "Source disk: $SOURCE"
echo "Destination disk: $DESTINATION"
read -p "Are you sure you want to clone the partition structure and file systems? This will overwrite $DESTINATION. (y/N): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Operation cancelled."
    exit 1
fi

# The GPT tables exist on the start and end of the drive. Make sure to erase all of the tables
echo "Clearing all partition and filesystem metadata from $DESTINATION..."
sgdisk --zap-all "$DESTINATION" || { echo "Failed to zap $DESTINATION."; exit 1; }

# Get total disk size in sectors for destination
DEST_TOTAL_SECTORS=$(blockdev --getsz "$DESTINATION")
echo "Destination disk total sectors: $DEST_TOTAL_SECTORS"

# Get total used sectors from source (end of last partition)
SOURCE_LAST_SECTOR=$(sgdisk -p "$SOURCE" | grep -E "^ *[0-9]+" | awk '{print $3}' | sort -n | tail -1)
echo "Source last used sector: $SOURCE_LAST_SECTOR"

# Calculate unallocated space on destination (reserve 34 sectors for backup GPT)
UNALLOCATED_SECTORS=$((DEST_TOTAL_SECTORS - SOURCE_LAST_SECTOR - 34))
echo "Unallocated sectors on destination: $UNALLOCATED_SECTORS"

# Calculate 90% of unallocated space to add to APP partition
if [[ $UNALLOCATED_SECTORS -gt 1000000 ]]; then
    SECTORS_TO_ADD=$((UNALLOCATED_SECTORS * 90 / 100))
    EXTRA_GB=$((SECTORS_TO_ADD * 512 / 1024 / 1024 / 1024))
    echo "Will add $SECTORS_TO_ADD sectors (~${EXTRA_GB}GB) to APP partition"
else
    SECTORS_TO_ADD=0
    echo "Not enough unallocated space to expand APP partition"
fi

# Find the APP partition number and get its info from source
APP_PART_NUM=$(sgdisk -p "$SOURCE" | grep -i "APP" | awk '{print $1}' | head -1)
if [[ -z "$APP_PART_NUM" ]]; then
    APP_PART_NUM=1  # Default to partition 1 if APP not found by name
fi
echo "APP partition number: $APP_PART_NUM"

# Get APP partition info from source
APP_INFO=$(sgdisk -i "$APP_PART_NUM" "$SOURCE")
APP_START=$(echo "$APP_INFO" | grep "First sector:" | awk '{print $3}')
APP_END=$(echo "$APP_INFO" | grep "Last sector:" | awk '{print $3}')
APP_TYPE=$(echo "$APP_INFO" | grep "Partition GUID code:" | awk '{print $4}')
APP_NAME=$(echo "$APP_INFO" | grep "Partition name:" | sed "s/Partition name: '\(.*\)'/\1/")
APP_SIZE=$((APP_END - APP_START + 1))

echo "Source APP partition: start=$APP_START, end=$APP_END, size=$APP_SIZE sectors"

# Calculate new APP end sector (expanded)
NEW_APP_END=$((APP_END + SECTORS_TO_ADD))
NEW_APP_SIZE=$((NEW_APP_END - APP_START + 1))
NEW_APP_SIZE_GB=$((NEW_APP_SIZE * 512 / 1024 / 1024 / 1024))
echo "New APP partition will be: start=$APP_START, end=$NEW_APP_END, size ~${NEW_APP_SIZE_GB}GB"

# Now create all partitions on destination with APP expanded and others shifted
echo ""
echo "Creating partitions on $DESTINATION with expanded APP partition..."
echo "All partitions after APP will be shifted by $SECTORS_TO_ADD sectors"
echo ""

# Get list of all partitions from source, sorted by partition number
PARTITIONS=$(sgdisk -p "$SOURCE" | grep -E "^ *[0-9]+" | awk '{print $1}' | sort -n)

for PART_NUM in $PARTITIONS; do
    # Get partition info from source
    PART_INFO=$(sgdisk -i "$PART_NUM" "$SOURCE")
    PART_START=$(echo "$PART_INFO" | grep "First sector:" | awk '{print $3}')
    PART_END=$(echo "$PART_INFO" | grep "Last sector:" | awk '{print $3}')
    PART_TYPE=$(echo "$PART_INFO" | grep "Partition GUID code:" | awk '{print $4}')
    PART_NAME=$(echo "$PART_INFO" | grep "Partition name:" | sed "s/Partition name: '\(.*\)'/\1/")
    
    if [[ "$PART_NUM" -eq "$APP_PART_NUM" ]]; then
        # This is the APP partition - create it with expanded size
        NEW_START=$PART_START
        NEW_END=$NEW_APP_END
        echo "Creating partition $PART_NUM (APP - EXPANDED): start=$NEW_START, end=$NEW_END"
    else
        # This is another partition - shift it by the amount we expanded APP
        NEW_START=$((PART_START + SECTORS_TO_ADD))
        NEW_END=$((PART_END + SECTORS_TO_ADD))
        echo "Creating partition $PART_NUM ($PART_NAME): start=$NEW_START, end=$NEW_END (shifted +$SECTORS_TO_ADD)"
    fi
    
    # Create the partition
    sgdisk -n "${PART_NUM}:${NEW_START}:${NEW_END}" \
           -t "${PART_NUM}:${PART_TYPE}" \
           -c "${PART_NUM}:${PART_NAME}" \
           "$DESTINATION" || { echo "Failed to create partition $PART_NUM"; exit 1; }
done

echo ""
echo "All partitions created successfully!"

# Modify PARTUUIDs on destination disk
echo "Randomizing GUIDs for $DESTINATION..."
sgdisk --randomize-guids "$DESTINATION" || { echo "Failed to randomize GUIDs on $DESTINATION."; exit 1; }

# Move backup GPT to end of disk
echo "Moving backup GPT header to end of disk..."
sgdisk -e "$DESTINATION" || echo "Warning: Could not move GPT backup header"

# Store expansion info for later display
ACTUAL_EXPANSION=$SECTORS_TO_ADD
EXPANSION_GB=$EXTRA_GB

echo "Flushing disk writes..."
sync

# Inform the OS about the partition table changes
echo "Reloading partition table on $DESTINATION..."
partprobe "$DESTINATION" || {
    echo "partprobe failed, forcing partition table reread..."
    blockdev --rereadpt "$DESTINATION" || { echo "Failed to reread partition table."; exit 1; }
}

# Ensure system is aware of changes
udevadm settle

# Replicate file systems from source to destination
echo "Replicating file systems..."
for PART in $(lsblk -ln -o NAME -p "$DESTINATION" | grep -E "${DESTINATION}p?[0-9]+$"); do
    # Get the corresponding source partition
    PART_NUM=$(echo "$PART" | grep -oE '[0-9]+$')

    # Handle partition naming difference for source device
    if [[ "$SOURCE" == *"mmcblk"* || "$SOURCE" == *"nvme"* ]]; then
        SOURCE_PART="${SOURCE}p${PART_NUM}"
    else
        SOURCE_PART="${SOURCE}${PART_NUM}"
    fi

    # Echo the destination partition being processed
    echo "Processing destination partition: $PART"
    echo "Corresponding source partition: $SOURCE_PART"

    # Check if the source partition has a file system
    SRC_FSTYPE=$(blkid -o value -s TYPE "$SOURCE_PART")
    echo "Source partition: $SOURCE_PART, Detected filesystem: ${SRC_FSTYPE:-None}"

    # Get the size of destination partition
    DEST_SIZE=$(blockdev --getsize64 "$PART")
    DEST_SIZE_GB=$((DEST_SIZE / 1024 / 1024 / 1024))
    echo "Destination partition size: ${DEST_SIZE_GB}GB"

    if [[ -n "$SRC_FSTYPE" ]]; then
        case "$SRC_FSTYPE" in
            ext[234])
                echo "Creating ext4 filesystem on $PART (${DEST_SIZE_GB}GB)..."
                mkfs.ext4 -F "$PART" && echo "ext4 filesystem created successfully on $PART."
                ;;
            vfat|fat32)
                echo "Creating FAT32 filesystem on $PART..."
                mkfs.vfat -F 32 "$PART" && echo "FAT32 filesystem created successfully on $PART."
                ;;
            swap)
                echo "Creating swap on $PART..."
                mkswap "$PART" && echo "Swap filesystem created successfully on $PART."
                ;;
            *)
                echo "Unsupported filesystem $SRC_FSTYPE on $SOURCE_PART. Skipping $PART..."
                ;;
        esac
    else
        echo "Source partition $SOURCE_PART has no filesystem. Leaving $PART empty."
    fi
done

# Ensure all filesystem changes are committed
echo "Flushing all writes before UUID adjustments..."
sync


# Adjust filesystem UUIDs
echo "Adjusting filesystem UUIDs..."
for PART in $(lsblk -ln -o NAME -p "$DESTINATION" | grep -E "${DESTINATION}p?[0-9]+$"); do
    FSTYPE=$(blkid -o value -s TYPE "$PART")
    PART_NUM=$(echo "$PART" | grep -oE '[0-9]+$')

    # Determine corresponding source partition
    if [[ "$SOURCE" == *"mmcblk"* || "$SOURCE" == *"nvme"* ]]; then
        SOURCE_PART="${SOURCE}p${PART_NUM}"
    else
        SOURCE_PART="${SOURCE}${PART_NUM}"
    fi

    echo "Processing destination partition: $PART (type: $FSTYPE)"
    echo "Corresponding source partition: $SOURCE_PART"

    if [[ -n "$FSTYPE" ]]; then
        case "$FSTYPE" in
            ext[234])
                echo "Checking filesystem on $PART..."
                e2fsck -f "$PART" && tune2fs -U random "$PART" && echo "Updated UUID for $PART."
                sync
                ;;
            swap)
                mkswap -U "$(uuidgen)" "$PART" && echo "Updated UUID for $PART."
                sync
                ;;
            vfat|fat32)
                # Fetch the source FAT32 label correctly now
                SRC_LABEL=$(blkid -o value -s LABEL "$SOURCE_PART")
                echo "Source FAT32 label for $SOURCE_PART: ${SRC_LABEL:-<none>}"

                if [[ -n "$SRC_LABEL" ]]; then
                    echo "Setting FAT32 label: $SRC_LABEL on $PART..."
                    if ! fatlabel "$PART" "$SRC_LABEL"; then
                        echo "Error: FAT32 label '$SRC_LABEL' failed to set on $PART."
                    else
                        echo "Updated label and UUID for $PART with label: $SRC_LABEL."
                    fi
                else
                    echo "Source FAT32 partition $SOURCE_PART has no label. Skipping label assignment."
                fi
                # Get the source partition label (PARTLABEL)
                SRC_PARTLABEL=$(blkid -o value -s PARTLABEL "$SOURCE_PART")
                echo "Source PARTLABEL for $SOURCE_PART: ${SRC_PARTLABEL:-<none>}"

                if [[ -n "$SRC_PARTLABEL" ]]; then
                    echo "Setting PARTLABEL: $SRC_PARTLABEL on $PART..."
                    sgdisk --change-name="${PART_NUM}:${SRC_PARTLABEL}" "$DESTINATION" && echo "Updated PARTLABEL for $PART to $SRC_PARTLABEL."
                else
                    echo "Source partition $SOURCE_PART has no PARTLABEL. Skipping PARTLABEL update."
                fi

                # Ensure partition table changes are recognized
                sync
                partprobe "$DESTINATION"
                udevadm settle
                ;;
            *)
                echo "Filesystem type $FSTYPE on $PART not supported for UUID adjustment."
                ;;
        esac
    else
        echo "Skipping $PART: No filesystem detected."
    fi
done

# Ensure UUID changes are properly recognized
echo "Forcing partition table reread after UUID updates..."
blockdev --rereadpt "$DESTINATION" || echo "Warning: Could not reread partition table."
udevadm settle
sync  # Final sync to make sure everything is written

# Display partition summary
echo ""
echo "=========================================="
echo "Partition creation complete!"
echo "=========================================="
echo ""
echo "Summary:"
sgdisk -p "$DESTINATION"
echo ""
if [[ ${ACTUAL_EXPANSION:-0} -gt 0 ]]; then
    echo "✓ APP partition (partition $APP_PART_NUM) was expanded by ~${EXPANSION_GB:-0}GB"
    echo "  All other partitions were shifted to accommodate the larger APP"
    echo ""
fi
echo "Next step: Run copy_partitions.sh to clone the data"
echo "=========================================="

echo "Partition cloning, file system replication, and UUID adjustment complete."
