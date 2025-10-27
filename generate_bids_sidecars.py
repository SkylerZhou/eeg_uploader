#!/usr/bin/env python3
"""
Generate BIDS sidecar files for the reorganized EEG data.
Discovers the BIDS structure and creates appropriate sidecars.
"""

import os
import sys
from pathlib import Path
from sidecar.eegJSON import eegJSON

# ==== Helper Functions ==== #
def find_bids_path(output_dir):
    """
    Find all EEG session directories in the output folder.
    Returns list of tuples: (patient_id, age, eeg_dir_path, edf_file_path)
    """
    path = []
    output_path = Path(output_dir)
    
    # Pattern: output/PRV-{patient_id}/primary/sub-PRV-{patient_id}/ses-visit-m{age}/eeg/
    for dataset_dir in output_path.glob("PRV-*"):
        patient_id = dataset_dir.name.replace("PRV-", "")
        
        # Navigate to subject directory
        subject_dir = dataset_dir / "primary" / f"sub-PRV-{patient_id}"
        
        if not subject_dir.exists():
            continue
        
        # Find all session directories
        for session_dir in subject_dir.glob("ses-visit-m*"):
            # Extract age from session name (ses-visit-m15 -> 15)
            age = session_dir.name.replace("ses-visit-m", "")
            
            # Check for eeg directory
            eeg_dir = session_dir / "eeg"
            if eeg_dir.exists():
                # Find EDF file in this directory
                edf_files = list(eeg_dir.glob("*.edf"))
                if edf_files:
                    path.append({
                        'patient_id': patient_id,
                        'age': age,
                        'subject_dir': str(subject_dir),
                        'session_dir': str(session_dir),
                        'eeg_dir': str(eeg_dir),
                        'edf_file': str(edf_files[0])
                    })
    
    return path


# ==== Main Sidecar Generation Function ==== #
def handle_eeg_json(path_info, output_base_dir):
    """
    Generate eeg.json sidecar.
    For now, uses default values for testing.
    """
    patient_id = path_info['patient_id']    
    age = path_info['age']
    subject_dir = path_info['subject_dir']
    session_dir = path_info['session_dir']
    #eeg_dir = path_info['eeg_dir']
    #edf_file = path_info['edf_file']
    
    print(f"  Generating eeg.json for PRV-{patient_id}, session visit-m{age}")
    
    # For testing: use placeholder values (no EDF extraction yet)
    # TODO: Replace with actual EDF extraction
    edf_data = {
        "SamplingFrequency": 512,  # Placeholder for testing
    }
    
    # TODO: Uncomment this when ready to extract from EDF
    '''
    import pyedflib
    f = pyedflib.EdfReader(edf_file)
    edf_data = {
        "SamplingFrequency": f.getSampleFrequency(0),
        "RecordingDuration": f.getFileDuration(),
        "EEGChannelCount": f.signals_in_file,
    }
    f.close()
    '''
    
    # Calculate the bids_path relative to output_base_dir
    # We want: PRV-{patient_id}/primary/sub-PRV-{patient_id}/ses-visit-m{age}/eeg/
    bids_path = f"PRV-{patient_id}/primary/sub-PRV-{patient_id}/ses-visit-m{age}/eeg/"
    
    # Create custom filename following BIDS format: sub-PRV-<ptid>-<age>_task-rest_eeg.json
    custom_filename = f"sub-PRV-{patient_id}-{age}_task-rest_eeg.json"
    
    # Create sidecar with extracted data (or defaults)
    eeg_sidecar = eegJSON(
        fields=edf_data,
        bids_path=bids_path,
        filename=custom_filename
    )
    
    # Validate and save
    try:
        if eeg_sidecar.validate():
            saved_path = eeg_sidecar.save(output_dir=output_base_dir)
            print(f"    ✓ Saved: {saved_path}")
            return True
    except Exception as e:
        print(f"    ✗ Error: {e}")
        return False


# ==== Main Execution ==== #
def main():
    """Main execution function."""
    script_dir = Path(__file__).parent
    output_dir = script_dir / "output"
    
    print("=" * 50)
    print("BIDS Sidecar Generator")
    print("=" * 50)
    
    # Find all EEG paths
    print("\n1. Discovering EEG pathes...")
    pathes = find_bids_path(output_dir)
    print(f"   Found {len(pathes)} session(s)")
    
    if not pathes:
        print("   No EEG path found. Exiting.")
        return 0
    
    # Generate _eeg.json for each path
    print("\n2. Generating _eeg.json sidecars...")
    successful = 0
    failed = 0
    
    for path in pathes:
        if handle_eeg_json(path, str(output_dir)):
            successful += 1
        else:
            failed += 1
    
    # Summary
    print("\n" + "=" * 50)
    print(f"Summary: {successful} successful, {failed} failed")
    print("=" * 50)
    
    return 0 if failed == 0 else 1

if __name__ == "__main__":
    sys.exit(main())
