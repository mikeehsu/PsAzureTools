const { BlockBlobClient, AnonymousCredential } = require("@azure/storage-blob");

blobUpload = async function (file, url, container, sasKey) {
    var blobName = buildBlobName(file);
    var login = `${url}/${container}/${blobName}?${sasKey}`;
    var blockBlobClient = new BlockBlobClient(login, new AnonymousCredential());

    try {
        document.querySelector('#message').textContent = file.name + " uploading...";
        result = await blockBlobClient.uploadBrowserData(file);
        document.querySelector('#message').textContent = file.name + " successfully uploaded";
    } catch (error) {
        document.querySelector('#message').textContent = "Upload failed. Please make sure URL & SAS token are vaild. - " + "\n" + error;
        console.error(error);
        // expected output: ReferenceError: nonExistentFunction is not defined
        // Note - error messages will vary depending on browser
    }

}

function buildBlobName(file) {
    // var filename = file.name.substring(0, file.name.lastIndexOf('.'));
    // var ext = file.name.substring(file.name.lastIndexOf('.'));
    return file.name + '.' + Math.random().toString(16).slice(2);
}