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

# Backup the GPT partition table from the source disk
echo "Backing up partition table from $SOURCE..."
sgdisk --backup=table.bak "$SOURCE" || { echo "Failed to backup partition table from $SOURCE."; exit 1; }

# Restore the partition table to the destination disk
echo "Restoring partition table to $DESTINATION..."
sgdisk --load-backup=table.bak "$DESTINATION" || { echo "Failed to restore partition table to $DESTINATION."; exit 1; }

# Modify PARTUUIDs on destination disk
echo "Randomizing GUIDs for $DESTINATION..."
sgdisk --randomize-guids "$DESTINATION" || { echo "Failed to randomize GUIDs on $DESTINATION."; exit 1; }

# Calculate and allocate 90% of unallocated space to APP partition
echo "Calculating unallocated space and expanding APP partition..."

# Get total disk size in sectors using blockdev (more reliable)
TOTAL_SECTORS=$(blockdev --getsz "$DESTINATION")
echo "Total disk sectors: $TOTAL_SECTORS"

# First, we need to move the backup GPT to the end of the larger disk
echo "Moving backup GPT header to end of disk..."
sgdisk -e "$DESTINATION" || echo "Warning: Could not move GPT backup header"

# Get the last used sector from the partition table (this is the end of the last partition)
LAST_USED_SECTOR=$(sgdisk -p "$DESTINATION" | grep -E "^ *[0-9]+" | awk '{print $3}' | sort -n | tail -1)
echo "Last used sector: $LAST_USED_SECTOR"

# Find which partition number ends at the last used sector (this is the expandable partition)
LAST_PART_NUM=$(sgdisk -p "$DESTINATION" | grep -E "^ *[0-9]+" | awk -v last="$LAST_USED_SECTOR" '$3 == last {print $1}')
echo "Last partition number (expandable): $LAST_PART_NUM"

# Calculate unallocated sectors (reserve 34 sectors for backup GPT at the end)
UNALLOCATED_SECTORS=$((TOTAL_SECTORS - LAST_USED_SECTOR - 34))
echo "Unallocated sectors: $UNALLOCATED_SECTORS"

if [[ $UNALLOCATED_SECTORS -gt 1000000 ]] && [[ -n "$LAST_PART_NUM" ]]; then
    # Calculate 90% of unallocated space
    SECTORS_TO_ADD=$((UNALLOCATED_SECTORS * 90 / 100))
    echo "Sectors to add to partition $LAST_PART_NUM (90% of unallocated): $SECTORS_TO_ADD"
    
    # Get current start and end sector of the last partition on DESTINATION
    PART_INFO=$(sgdisk -i "$LAST_PART_NUM" "$DESTINATION")
    PART_START=$(echo "$PART_INFO" | grep "First sector:" | awk '{print $3}')
    CURRENT_END=$(echo "$PART_INFO" | grep "Last sector:" | awk '{print $3}')
    PART_NAME=$(echo "$PART_INFO" | grep "Partition name:" | sed "s/Partition name: '\(.*\)'/\1/")
    echo "Partition $LAST_PART_NUM ('$PART_NAME'): start=$PART_START, end=$CURRENT_END"
    
    # Check if this is the APP partition - if not, warn the user
    if [[ "$PART_NAME" != "APP" ]]; then
        echo ""
        echo "NOTE: The last partition is '$PART_NAME', not 'APP'."
        echo "      On Jetson, the APP partition is typically not the last partition."
        echo "      The unallocated space will be added to partition $LAST_PART_NUM ('$PART_NAME')."
        echo ""
        echo "      If you want to expand the APP partition instead, you would need to"
        echo "      manually rearrange the partition layout, which is complex and risky."
        echo ""
        read -p "Do you want to expand partition $LAST_PART_NUM ('$PART_NAME') instead? (y/N): " EXPAND_CONFIRM
        if [[ "$EXPAND_CONFIRM" != "y" && "$EXPAND_CONFIRM" != "Y" ]]; then
            echo "Skipping partition expansion. You can manually resize later."
            SECTORS_TO_ADD=0
        fi
    fi
    
    if [[ $SECTORS_TO_ADD -gt 0 ]]; then
        # Calculate new end sector
        NEW_END=$((CURRENT_END + SECTORS_TO_ADD))
        
        # Make sure we don't exceed disk size (leave 34 sectors for backup GPT)
        MAX_END=$((TOTAL_SECTORS - 34))
        if [[ $NEW_END -gt $MAX_END ]]; then
            NEW_END=$MAX_END
        fi
        
        echo "Expanding partition $LAST_PART_NUM using sfdisk..."
        echo "  Start: $PART_START (unchanged), End: $NEW_END (was $CURRENT_END)"
        
        # Use sfdisk to resize the partition in place
        echo ", +${SECTORS_TO_ADD}" | sfdisk --no-reread -N "$LAST_PART_NUM" "$DESTINATION" 2>/dev/null || {
            echo "sfdisk resize failed, trying alternative method with parted..."
            parted -s "$DESTINATION" resizepart "$LAST_PART_NUM" "${NEW_END}s" || {
                echo "Warning: Failed to expand partition $LAST_PART_NUM. Continuing without expansion."
                echo "You can manually resize the partition later using GParted or similar tools."
            }
        }
        
        # Calculate actual expansion
        ACTUAL_EXPANSION=$((NEW_END - CURRENT_END))
        EXPANSION_GB=$((ACTUAL_EXPANSION * 512 / 1024 / 1024 / 1024))
        echo "Successfully expanded partition $LAST_PART_NUM by $ACTUAL_EXPANSION sectors (~${EXPANSION_GB} GB)"
        
        # Verify the change
        echo "Verifying partition $LAST_PART_NUM on $DESTINATION:"
        sgdisk -i "$LAST_PART_NUM" "$DESTINATION" | grep -E "(First sector|Last sector|Partition size)"
    fi
else
    if [[ -z "$LAST_PART_NUM" ]]; then
        echo "Could not determine the last partition. Skipping expansion."
    else
        echo "Unallocated space is less than ~500MB. Skipping partition expansion."
    fi
fi

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
    echo "✓ Partition $LAST_PART_NUM ('$PART_NAME') was automatically expanded"
    echo "  by ~${EXPANSION_GB}GB (90% of unallocated space)"
    echo ""
fi
echo "Next step: Run copy_partitions.sh to clone the data"
echo "=========================================="

# Clean up
rm -f table.bak

echo "Partition cloning, file system replication, and UUID adjustment complete."
