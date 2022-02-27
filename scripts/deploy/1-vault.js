async function main() {
  const Vault = await ethers.getContractFactory('ReaperVaultv1_4');

  const wantAddress = '0xfbF535224f1f473b6438bf50Fbf3200b8659eDDE';
  const tokenName = 'ProtoFi PROTO-FTM Crypt';
  const tokenSymbol = 'rfPF-PROTO-FTM';
  const depositFee = ethers.BigNumber.from(0);
  const tvlCap = ethers.utils.parseEther('1000');

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
