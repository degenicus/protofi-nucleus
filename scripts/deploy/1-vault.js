async function main() {
  const Vault = await ethers.getContractFactory('ReaperVaultv1_3');

  const ftmUsdcLPAddress = '0x1a8a4Dc716e9379e84E907B0c740d2c622F7cfb7';
  const wantAddress = ftmUsdcLPAddress;
  const tokenName = 'Protofi FTM-USDC Vault';
  const tokenSymbol = 'rf-PF-FTM-USDC';
  const depositFee = 10;
  const tvlCap = ethers.utils.parseEther('0.002');

  const vault = await Vault.deploy(wantAddress, tokenName, tokenSymbol, depositFee, tvlCap);

  await vault.deployed();
  console.log('Vault deployed to:', vault.address);
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
