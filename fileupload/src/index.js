const { BlockBlobClient, AnonymousCredential } = require("@azure/storage-blob");

blobUpload = async function (folder, file, url, container, sasKey) {
    var blobName = folder + "/" + file.name;
    var login = `${url}/${container}/${blobName}?${sasKey}`;
    var blockBlobClient = new BlockBlobClient(login, new AnonymousCredential());

    try {
        document.querySelector('#message').textContent = "Uploading file(s)...";
        result = await blockBlobClient.uploadBrowserData(file);
        document.querySelector('#message').textContent = document.querySelector('#message').textContent + "\r\n" + file.name + " uploaded";
    } catch (error) {
        document.querySelector('#message').textContent = "Upload failed. Please make sure URL & SAS token are vaild. - " + "\n" + error;
        console.error(error);
        // expected output: ReferenceError: nonExistentFunction is not defined
        // Note - error messages will vary depending on browser
    }

}
