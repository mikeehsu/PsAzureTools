const { BlobServiceClient } = require("@azure/storage-blob");

function handleDrop(e) {
    const dt = e.dataTransfer;
    const files = dt.files;
    handleFiles({ target: { files } });
}

async function handleFiles(e) {
    const files = [...e.target.files];
    files.forEach(uploadFile);
}

uploadFile = async function (file) {
    // Create file item in list
    const fileItem = document.createElement('li');
    fileItem.className = 'file-item';
    fileItem.innerHTML = `
        <div style="flex-grow: 1;">
            <div>${file.name}</div>
            <div class="progress-bar">
                <div class="progress"></div>
            </div>
        </div>
    `;
    fileList.appendChild(fileItem);
    const progressBar = fileItem.querySelector('.progress');

    try {
        // Create BlobServiceClient using the UMD bundle
        sasUrl = url + "?" + document.querySelector('#sasKey').value

        const blobServiceClient = new BlobServiceClient(sasUrl);
        const containerClient = blobServiceClient.getContainerClient(containerName);
        const blobClient = containerClient.getBlockBlobClient(folder + "/" + file.name);

        // Upload file
        await blobClient.uploadData(file, {
            onProgress: (progress) => {
                const percentComplete = Math.round((progress.loadedBytes / file.size) * 100);
                progressBar.style.width = `${percentComplete}%`;
            }
        });

        // Add to completed list
        const completedItem = document.createElement('li');
        completedItem.className = 'completed-item';
        completedItem.innerHTML = `
            <svg width="16" height="16" viewBox="0 0 16 16">
                <path fill="#2E7D32" d="M6.667 12.277L3.11 8.72l1.11-1.11 2.447 2.447 5.557-5.557 1.11 1.11z"/>
            </svg>
            ${file.name}
        `;
        completedList.appendChild(completedItem);

        // Remove progress item after completion
        setTimeout(() => {
            fileList.removeChild(fileItem);
        }, 1000);

        // Show success message
        showStatus(`${file.name} uploaded successfully!`, 'success');
    } catch (error) {
        console.error(error);
        showStatus(`Error uploading ${file.name}: ${error.message}`, 'error');
    }
}
